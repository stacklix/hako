package me.stackli.doppel

import android.content.Context
import android.os.Build
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.InetSocketAddress
import java.net.Socket

internal data class RemoteControlConfig(
    val enabled: Boolean = false,
    val port: Int = 18080,
    val password: String = "",
    val token: String = "",
)

internal data class RemoteActionResult(
    val success: Boolean,
    val message: String,
)

internal object RemoteControlStore {
    private const val TAG = "DoppelRemoteStore"
    private const val PREFS_NAME = "doppel"
    private const val DIRECT_BOOT_PREFS_NAME = "doppel_direct_boot"
    private const val KEY_CONFIG = "config_json"
    private const val KEY_REMOTE_CONTROL = "remote_control_json"

    fun readRemoteConfig(context: Context): RemoteControlConfig {
        val remote = readConfigJson(context).optJSONObject("remoteControl")
            ?: readDirectBootRemoteControl(context)
        return RemoteControlConfig(
            enabled = remote.optBoolean("enabled", false),
            port = remote.optString("port").toIntOrNull()?.takeIf { it in 1024..65535 } ?: 18080,
            password = remote.optString("password"),
            token = remote.optString("token"),
        )
    }

    fun readConfigJson(context: Context): JSONObject {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val raw = prefs.getString(KEY_CONFIG, "{}") ?: "{}"
        return runCatching { JSONObject(raw) }
            .onFailure { Log.e(TAG, "配置解析失败", it) }
            .getOrDefault(JSONObject())
    }

    fun mergeConfig(context: Context, incoming: JSONObject) {
        val existing = readConfigJson(context)
        mergeRemoteJsonObjects(existing, incoming)
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_CONFIG, existing.toString())
            .apply()
        syncDirectBootConfig(context, existing)
    }

    fun syncDirectBootRemoteControl(context: Context) {
        syncDirectBootConfig(context)
    }

    fun syncDirectBootConfig(context: Context) {
        syncDirectBootConfig(context, readConfigJson(context))
    }

    fun buildSnapshot(context: Context): JSONObject {
        return DoppelSnapshotStore.buildSnapshotJson(context)
    }

    fun remoteControlStatusJson(context: Context): JSONObject {
        val config = readRemoteConfig(context)
        val health = checkRemoteControlHealth(config)
        return JSONObject()
            .put("ipAddresses", JSONArray(localIpAddresses()))
            .put("isRunning", health)
            .put("port", if (health) config.port else JSONObject.NULL)
    }

    private fun readDirectBootRemoteControl(context: Context): JSONObject {
        val directBootContext = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.createDeviceProtectedStorageContext()
        } else {
            context
        }
        val raw = directBootContext
            .getSharedPreferences(DIRECT_BOOT_PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_REMOTE_CONTROL, "{}") ?: "{}"
        return runCatching { JSONObject(raw) }
            .onFailure { Log.e(TAG, "Direct Boot 远程控制配置解析失败", it) }
            .getOrDefault(JSONObject())
    }

    private fun syncDirectBootRemoteControl(context: Context, config: JSONObject) {
        val remote = config.optJSONObject("remoteControl") ?: return
        val directBootContext = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.createDeviceProtectedStorageContext()
        } else {
            context
        }
        directBootContext
            .getSharedPreferences(DIRECT_BOOT_PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_REMOTE_CONTROL, remote.toString())
            .apply()
    }

    private fun syncDirectBootConfig(context: Context, config: JSONObject) {
        val directBootContext = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.createDeviceProtectedStorageContext()
        } else {
            context
        }
        directBootContext
            .getSharedPreferences(DIRECT_BOOT_PREFS_NAME, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY_CONFIG, config.toString())
            .apply()
        syncDirectBootRemoteControl(context, config)
    }

    private fun localIpAddresses(): List<String> {
        return runCatching {
            NetworkInterface.getNetworkInterfaces().toList()
                .filter { it.isUp && !it.isLoopback }
                .flatMap { networkInterface ->
                    networkInterface.inetAddresses.toList()
                        .filterIsInstance<Inet4Address>()
                        .filterNot { it.isLoopbackAddress }
                        .map { it.hostAddress.orEmpty() }
                }
                .filter { it.isNotBlank() }
                .distinct()
                .sorted()
        }.getOrDefault(emptyList())
    }

    private fun checkRemoteControlHealth(config: RemoteControlConfig): Boolean {
        if (!config.enabled || config.password.isBlank()) {
            return false
        }
        var isHealthy = false
        val thread = Thread {
            isHealthy = runCatching {
                Socket().use { socket ->
                    socket.connect(InetSocketAddress("127.0.0.1", config.port), HEALTH_TIMEOUT_MILLIS)
                    socket.soTimeout = HEALTH_TIMEOUT_MILLIS
                    val request = "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
                    socket.getOutputStream().write(request.toByteArray(Charsets.UTF_8))
                    socket.getOutputStream().flush()
                    val body = socket.getInputStream().readBytes().toString(Charsets.UTF_8)
                    body.startsWith("HTTP/1.1 200") && body.contains("doppel_remote_control")
                }
            }.getOrDefault(false)
        }
        thread.start()
        runCatching { thread.join(HEALTH_JOIN_TIMEOUT_MILLIS) }
        return isHealthy
    }

    private const val HEALTH_TIMEOUT_MILLIS = 250
    private const val HEALTH_JOIN_TIMEOUT_MILLIS = 350L
}

internal fun JSONObject.toMapValue(): Map<String, Any?> {
    return buildMap {
        keys().forEach { key -> put(key, normalizeRemoteJsonValue(opt(key))) }
    }
}

private fun JSONArray.toListValue(): List<Any?> {
    return buildList {
        for (index in 0 until length()) {
            add(normalizeRemoteJsonValue(opt(index)))
        }
    }
}

private fun normalizeRemoteJsonValue(value: Any?): Any? {
    return when (value) {
        is JSONObject -> value.toMapValue()
        is JSONArray -> value.toListValue()
        else -> if (value === JSONObject.NULL) null else value
    }
}

private fun mergeRemoteJsonObjects(target: JSONObject, incoming: JSONObject) {
    incoming.keys().forEach { key ->
        val incomingValue = incoming.get(key)
        if (incomingValue == JSONObject.NULL) {
            return@forEach
        }
        val existingValue = target.opt(key)
        if (existingValue is JSONObject && incomingValue is JSONObject) {
            mergeRemoteJsonObjects(existingValue, incomingValue)
        } else {
            target.put(key, incomingValue)
        }
    }
}
