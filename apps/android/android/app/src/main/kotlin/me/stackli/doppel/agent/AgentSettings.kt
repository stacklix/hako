package me.stackli.doppel.agent

import android.content.Context
import android.os.PowerManager
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.io.FileNotFoundException
import java.io.RandomAccessFile
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.KeyFactory
import java.security.Signature
import java.security.spec.MGF1ParameterSpec
import java.security.spec.PSSParameterSpec
import java.security.spec.X509EncodedKeySpec
import java.util.Base64
import java.util.concurrent.ConcurrentHashMap

internal data class AgentSettings(
    val enabled: Boolean,
    val server: String,
    val username: String,
    val allowSms: Boolean,
    val allowCalls: Boolean,
)

internal class AgentSettingsStore(private val context: Context) {
    fun read(): AgentSettings {
        val json = readFile(context, "hako-agent-settings.json")
        return AgentSettings(json.optBoolean("enabled"), json.optString("server"), json.optString("username"),
            json.optBoolean("allowSms"), json.optBoolean("allowCalls"))
    }

    fun save(json: JSONObject) {
        AgentProtocol.fields(json, setOf("enabled", "server", "username", "allowSms", "allowCalls"))
        for (name in listOf("enabled", "allowSms", "allowCalls")) {
            if (json.opt(name) !is Boolean) AgentProtocol.invalid("$name 需要为布尔值")
        }
        val enabled = json.getBoolean("enabled")
        val rawServer = json.optString("server").trim()
        val server = if (rawServer.isEmpty() && !enabled) "" else AgentProtocol.origin(rawServer)
        val username = json.optString("username").trim()
        if (username.length > 128 || username.any { it == '\n' || it == '\r' }) AgentProtocol.invalid("账号无效")
        if (enabled && (username.isEmpty() || AgentKeys.publicKey() == null)) {
            AgentProtocol.invalid("请填写账号并先生成设备密钥，将公钥登记到 Sora")
        }
        try {
            writeFile(context, "hako-agent-settings.json", JSONObject().put("enabled", enabled)
                .put("server", server).put("username", username).put("allowSms", json.getBoolean("allowSms"))
                .put("allowCalls", json.getBoolean("allowCalls")))
        } catch (_: Exception) {
            throw AgentError("storage_failed", "Agent 配置保存失败")
        }
    }

    fun snapshot(): JSONObject {
        val settings = read()
        val key = AgentKeys.publicKey()
        val manager = context.getSystemService(PowerManager::class.java)
        return JSONObject().put("enabled", settings.enabled).put("server", settings.server)
            .put("username", settings.username).put("allowSms", settings.allowSms)
            .put("allowCalls", settings.allowCalls).put("publicKey", key ?: "")
            .put("keyId", AgentKeys.keyId() ?: "")
            .put("batteryExempt", manager?.isIgnoringBatteryOptimizations(context.packageName) == true)
            .put("status", AgentRuntime.snapshot(context))
    }

    companion object {
        private val locks = ConcurrentHashMap<String, Any>()
        private fun <T> locked(context: Context, name: String, block: () -> T): T {
            val path = File(context.noBackupFilesDir, "$name.lock")
            return synchronized(locks.computeIfAbsent(path.absolutePath) { Any() }) {
                RandomAccessFile(path, "rw").use { file -> file.channel.lock().use { block() } }
            }
        }

        fun readFile(context: Context, name: String): JSONObject = locked(context, name) {
            try { JSONObject(AtomicFile(File(context.noBackupFilesDir, name)).readFully().toString(Charsets.UTF_8)) }
            catch (_: FileNotFoundException) { JSONObject() }
        }

        fun writeFile(context: Context, name: String, json: JSONObject) = locked(context, name) {
            val file = AtomicFile(File(context.noBackupFilesDir, name))
            val stream = file.startWrite()
            try { stream.write(json.toString().toByteArray(Charsets.UTF_8)); file.finishWrite(stream) }
            catch (error: Exception) { file.failWrite(stream); throw error }
        }

        fun updateFile(context: Context, name: String, update: (JSONObject) -> JSONObject) = locked(context, name) {
            val file = AtomicFile(File(context.noBackupFilesDir, name))
            val previous = try { JSONObject(file.readFully().toString(Charsets.UTF_8)) }
                catch (_: FileNotFoundException) { JSONObject() }
            val value = update(previous)
            val stream = file.startWrite()
            try { stream.write(value.toString().toByteArray(Charsets.UTF_8)); file.finishWrite(stream) }
            catch (error: Exception) { file.failWrite(stream); throw error }
        }
    }
}

internal object AgentKeys {
    private const val ALIAS = "hako-agent-rsa-v1"
    private fun store() = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }

    @Synchronized
    fun generate() {
        if (store().containsAlias(ALIAS)) return
        KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_RSA, "AndroidKeyStore").apply {
            initialize(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_SIGN)
                .setKeySize(3072).setDigests(KeyProperties.DIGEST_SHA256)
                .setSignaturePaddings(KeyProperties.SIGNATURE_PADDING_RSA_PSS).build())
        }.generateKeyPair()
    }

    fun publicKey(): String? {
        val bytes = store().getCertificate(ALIAS)?.publicKey?.encoded ?: return null
        return "-----BEGIN PUBLIC KEY-----\n" + Base64.getMimeEncoder(64, byteArrayOf(10)).encodeToString(bytes) +
            "\n-----END PUBLIC KEY-----"
    }

    fun keyId(): String? = store().getCertificate(ALIAS)?.publicKey?.encoded?.let(AgentProtocol::keyId)

    fun sign(payload: ByteArray): String {
        val key = store().getKey(ALIAS, null) as? java.security.PrivateKey
            ?: throw AgentError("key_missing", "设备密钥不存在，请重新登记")
        val signature = Signature.getInstance("SHA256withRSA/PSS")
        signature.initSign(key)
        // Android Keystore fixes PSS parameters from the SHA-256 algorithm; it does not
        // implement Signature.setParameter. KeyMint uses the same digest for MGF1 and salt size.
        signature.update(payload)
        val bytes = signature.sign()
        val publicBytes = store().getCertificate(ALIAS).publicKey.encoded
        val publicKey = KeyFactory.getInstance("RSA").generatePublic(X509EncodedKeySpec(publicBytes))
        val verifier = Signature.getInstance("SHA256withRSA/PSS")
        verifier.initVerify(publicKey)
        verifier.setParameter(PSSParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA256, 32, 1))
        verifier.update(payload)
        if (!verifier.verify(bytes)) throw AgentError("authentication_failed", "设备签名参数不符合 Sora 的 RSA-PSS 要求")
        return Base64.getEncoder().encodeToString(bytes)
    }
}
