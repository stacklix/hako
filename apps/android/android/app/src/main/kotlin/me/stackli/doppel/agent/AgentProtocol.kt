package me.stackli.doppel.agent

import org.json.JSONArray
import org.json.JSONObject
import java.net.URI
import java.nio.charset.StandardCharsets.UTF_8
import java.security.MessageDigest
import java.util.Base64

internal class AgentError(val code: String, override val message: String) : Exception(message)

internal data class AgentCapability(val name: String, val aggregate: Boolean = false) {
    fun json() = JSONObject().put("name", name).put("version", 1)
}

internal object AgentProtocol {
    const val VERSION = 4
    const val MAX_BYTES = 64 * 1024
    const val MINIMUM_SERVER = "0.8.0"
    val capabilities = listOf(
        AgentCapability(AgentVersions.COMMAND),
        AgentCapability("query.device.status", true),
        AgentCapability(AgentStorage.COMMAND, true),
        AgentCapability(AgentBattery.COMMAND, true),
        AgentCapability(AgentWifi.COMMAND, true),
        AgentCapability(AgentScreen.COMMAND, true),
        AgentCapability("query.network.lan", true),
        AgentCapability("query.telephony.sims", true),
        AgentCapability("query.sms.messages"),
        AgentCapability("query.telephony.calls"),
        AgentCapability("query.device.operation"),
        AgentCapability("action.sms.send"),
        AgentCapability("action.telephony.call"),
    )

    fun manifest() = JSONArray(capabilities.map { it.json() })

    fun aggregate(query: (String) -> JSONObject): JSONObject {
        val data = JSONObject()
        capabilities.filter { it.aggregate }.forEach { capability ->
            val item = JSONObject().put("version", 1)
            try { item.put("result", query(capability.name)) }
            catch (e: AgentError) { item.put("error", error(e)) }
            catch (_: Exception) { item.put("error", error(AgentError("query_failed", "状态读取失败"))) }
            data.put(capability.name, item)
        }
        return JSONObject().put("data", data)
    }

    fun origin(value: String): String {
        val uri = try { URI(value.trim()) } catch (_: Exception) { invalid("服务器地址无效") }
        if (uri.scheme != "https" || uri.host.isNullOrBlank() || uri.rawUserInfo != null ||
            uri.rawQuery != null || uri.rawFragment != null || uri.rawPath !in listOf("", "/") ||
            uri.port !in -1..65535 || uri.port == 0
        ) invalid("服务器地址需要为 HTTPS 域名和可选端口，不包含路径、账号或查询参数")
        return URI("https", null, uri.host.lowercase(), if (uri.port == 443) -1 else uri.port, null, null, null).toString()
    }

    fun checkChallenge(payload: ByteArray, origin: String, username: String, keyId: String) {
        val prefix = "hako-agent-auth/v4\n$origin\n$username\n$keyId\n"
        val text = payload.toString(UTF_8)
        if (!text.startsWith(prefix) || text.length <= prefix.length || '\n' in text.substring(prefix.length)) {
            throw AgentError("authentication_failed", "服务端身份挑战与当前配置不匹配")
        }
    }

    fun keyId(spki: ByteArray): String = Base64.getUrlEncoder().withoutPadding()
        .encodeToString(MessageDigest.getInstance("SHA-256").digest(spki))

    fun compatibleServer(version: String): Boolean {
        val parts = version.split('.')
        if (parts.size != 3 || parts.any { !it.matches(Regex("0|[1-9][0-9]*")) }) return false
        val values = parts.map { it.toIntOrNull() ?: return false }
        return values[0] == 0 && values[1] == 8 && values[2] >= 0
    }

    fun request(message: JSONObject): Triple<String, Int, JSONObject> {
        fields(message, setOf("type", "id", "method", "version", "params"))
        val method = string(message, "method", 100)
        string(message, "id", 128)
        val version = message.opt("version")
        if (version !is Int || version < 1) invalid("命令版本需要为正整数")
        val params = message.opt("params") as? JSONObject ?: invalid("params 需要为 JSON 对象")
        return Triple(method, version, params)
    }

    fun fields(params: JSONObject, allowed: Set<String>) {
        if (params.keys().asSequence().any { it !in allowed }) invalid("参数包含不支持的字段")
    }

    fun string(params: JSONObject, name: String, max: Int): String {
        val value = params.opt(name) as? String ?: invalid("缺少字符串参数 $name")
        if (value.isBlank() || value.length > max) invalid("参数 $name 为空或超过长度限制")
        return value
    }

    fun limit(params: JSONObject): Int {
        if (!params.has("limit")) return 20
        val limit = params.opt("limit")
        if (limit !is Int || limit !in 1..50) invalid("limit 需要为 1 到 50 的整数")
        return limit
    }

    fun cursor(params: JSONObject): Long? {
        if (!params.has("cursor")) return null
        val text = params.opt("cursor") as? String ?: invalid("cursor 需要为字符串")
        return text.toLongOrNull()?.takeIf { it > 0 } ?: invalid("cursor 无效")
    }

    fun error(error: AgentError) = JSONObject().put("code", error.code).put("message", error.message)
    fun invalid(message: String): Nothing = throw AgentError("invalid_params", message)
}
