package me.stackli.doppel

import android.content.Context
import android.content.Intent
import me.stackli.doppel.agent.AgentError
import me.stackli.doppel.agent.AgentKeys
import me.stackli.doppel.agent.AgentService
import me.stackli.doppel.agent.AgentSettingsStore
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedWriter
import java.io.OutputStreamWriter
import java.net.ServerSocket
import java.net.Socket
import java.net.URLDecoder
import java.security.SecureRandom
import java.time.Instant
import java.util.Base64
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap
import kotlin.concurrent.thread

internal class RemoteHttpServer(
    private val context: Context,
    private val config: RemoteControlConfig,
) {
    @Volatile
    var isRunning: Boolean = false
        private set

    private val sessions = ConcurrentHashMap<String, Long>()
    private val failedLogins = ConcurrentHashMap<String, MutableList<Long>>()
    private val random = SecureRandom()
    private var serverSocket: ServerSocket? = null

    fun start() {
        if (isRunning) {
            return
        }
        isRunning = true
        thread(name = "NamiRemoteHttp", isDaemon = true) {
            runCatching {
                ServerSocket(config.port).use { socket ->
                    serverSocket = socket
                    while (isRunning) {
                        val client = runCatching { socket.accept() }.getOrNull() ?: continue
                        thread(name = "NamiRemoteHttpClient", isDaemon = true) {
                            handleClient(client)
                        }
                    }
                }
            }.onFailure {
                if (isRunning) {
                    SmsPipeline.appendBusinessEvent(context, "远程 HTTP 控制启动失败：${it.message.orEmpty()}")
                }
            }
            isRunning = false
        }
    }

    fun stop() {
        isRunning = false
        runCatching { serverSocket?.close() }
        serverSocket = null
        sessions.clear()
    }

    private fun handleClient(socket: Socket) {
        socket.use { client ->
            val request = readRequest(client) ?: return
            val response = route(request)
            BufferedWriter(OutputStreamWriter(client.getOutputStream(), Charsets.UTF_8)).use {
                it.write(response.toHttp())
                it.flush()
            }
        }
    }

    private fun route(request: HttpRequest): HttpResponse {
        return when {
            request.method == "GET" && request.path == "/health" -> json(
                200,
                JSONObject()
                    .put("ok", true)
                    .put("service", "doppel_remote_control")
                    .put("port", config.port),
            )
            request.method == "GET" && request.path == "/" -> asset(
                path = "remote/index.html",
                contentType = "text/html; charset=utf-8",
            )
            request.method == "GET" && request.path.startsWith("/remote/") -> asset(
                path = request.path.removePrefix("/"),
                contentType = contentTypeFor(request.path),
            )
            request.method == "POST" && request.path == "/login" -> login(request)
            request.method == "POST" && request.path == "/logout" -> logout(request)
            request.path.startsWith("/api/") && !isAuthenticated(request) -> json(
                401,
                JSONObject().put("error", "unauthorized"),
            )
            request.method == "GET" && request.path == "/api/snapshot" -> json(
                200,
                RemoteControlStore.buildSnapshot(context),
            )
            request.method == "POST" && request.path == "/api/sms/send" -> sendSms(request)
            request.method == "POST" && request.path == "/api/call/start" -> startCall(request)
            request.method == "POST" && request.path == "/api/config" -> saveConfig(request)
            request.method == "GET" && request.path == "/api/agent/settings" -> agentSettings()
            request.method == "POST" && request.path == "/api/agent/settings" -> agentSettings(request)
            request.method == "POST" && request.path == "/api/agent/key" -> agentSettings(generateKey = true)
            else -> json(404, JSONObject().put("error", "not_found"))
        }
    }

    private fun login(request: HttpRequest): HttpResponse {
        val clientKey = request.remoteAddress
        if (isRateLimited(clientKey)) {
            return json(429, JSONObject().put("error", "too_many_attempts"))
        }
        val body = request.jsonBody()
        val password = body.optString("password")
        if (password != config.password) {
            recordFailedLogin(clientKey)
            return json(401, JSONObject().put("error", "invalid_password"))
        }
        failedLogins.remove(clientKey)
        val session = newSessionId()
        sessions[session] = System.currentTimeMillis() + SESSION_TTL_MILLIS
        return json(
            status = 200,
            body = JSONObject().put("ok", true),
            headers = listOf("Set-Cookie: doppel_session=$session; Path=/; HttpOnly; SameSite=Lax"),
        )
    }

    private fun logout(request: HttpRequest): HttpResponse {
        sessionId(request)?.let { sessions.remove(it) }
        return json(
            status = 200,
            body = JSONObject().put("ok", true),
            headers = listOf("Set-Cookie: doppel_session=; Path=/; Max-Age=0; HttpOnly; SameSite=Lax"),
        )
    }

    private fun sendSms(request: HttpRequest): HttpResponse {
        val body = request.jsonBody()
        val result = SmsPipeline.sendRemoteSms(
            context = context,
            target = body.optString("to"),
            message = body.optString("message"),
            selectedSim = body.optString("sim"),
        )
        return actionResponse(result)
    }

    private fun startCall(request: HttpRequest): HttpResponse {
        val body = request.jsonBody()
        return actionResponse(
            SmsPipeline.startRemoteCall(
                context = context,
                number = body.optString("number"),
                selectedSim = body.optString("sim"),
            ),
        )
    }

    private fun saveConfig(request: HttpRequest): HttpResponse {
        val incoming = request.jsonBody().optJSONObject("config") ?: request.jsonBody()
        RemoteControlStore.mergeConfig(context, incoming)
        RemoteControlService.sync(context)
        return json(200, JSONObject().put("ok", true).put("snapshot", RemoteControlStore.buildSnapshot(context)))
    }

    // Uses the same native store and Keystore as the on-device settings page.
    // These routes pass through the /api authentication check above.
    private fun agentSettings(request: HttpRequest? = null, generateKey: Boolean = false): HttpResponse {
        return try {
            val store = AgentSettingsStore(context)
            if (generateKey) AgentKeys.generate()
            if (request != null) {
                store.save(request.jsonBody())
                AgentService.sync(context, restart = true)
            }
            if (request != null || generateKey) {
                context.sendBroadcast(Intent(ACTION_DOPPEL_SNAPSHOT_CHANGED).setPackage(context.packageName))
            }
            json(200, store.snapshot())
        } catch (error: AgentError) {
            json(400, JSONObject().put("error", error.code).put("message", error.message))
        } catch (_: Exception) {
            json(500, JSONObject().put("error", "agent_settings_failed")
                .put("message", "Agent 设置操作失败，请重试"))
        }
    }

    private fun actionResponse(result: RemoteActionResult): HttpResponse {
        return json(
            if (result.success) 200 else 400,
            JSONObject().put("ok", result.success).put("message", result.message),
        )
    }

    private fun isAuthenticated(request: HttpRequest): Boolean {
        if (hasValidToken(request)) {
            return true
        }
        val id = sessionId(request) ?: return false
        val expiresAt = sessions[id] ?: return false
        if (expiresAt < System.currentTimeMillis()) {
            sessions.remove(id)
            return false
        }
        sessions[id] = System.currentTimeMillis() + SESSION_TTL_MILLIS
        return true
    }

    private fun hasValidToken(request: HttpRequest): Boolean {
        if (config.token.isBlank()) {
            return false
        }
        val authHeader = request.headers["authorization"].orEmpty()
        val bearerToken = authHeader.substringAfter("Bearer ", missingDelimiterValue = "")
        val headerToken = request.headers["x-doppel-token"].orEmpty()
        return bearerToken == config.token || headerToken == config.token
    }

    private fun sessionId(request: HttpRequest): String? {
        val cookie = request.headers["cookie"].orEmpty()
        return cookie.split(";")
            .map { it.trim() }
            .firstOrNull { it.startsWith("doppel_session=") }
            ?.substringAfter("=")
            ?.takeIf { it.isNotBlank() }
    }

    private fun isRateLimited(clientKey: String): Boolean {
        val now = System.currentTimeMillis()
        val attempts = failedLogins[clientKey].orEmpty().filter { now - it <= LOGIN_WINDOW_MILLIS }
        return attempts.size >= 5
    }

    private fun recordFailedLogin(clientKey: String) {
        val now = System.currentTimeMillis()
        val attempts = failedLogins.getOrPut(clientKey) { mutableListOf() }
        attempts.removeAll { now - it > LOGIN_WINDOW_MILLIS }
        attempts.add(now)
    }

    private fun newSessionId(): String {
        val bytes = ByteArray(32)
        random.nextBytes(bytes)
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes)
    }

    private fun readRequest(socket: Socket): HttpRequest? {
        socket.soTimeout = 15000
        val input = BufferedInputStream(socket.getInputStream())
        val headerBytes = mutableListOf<Byte>()
        var matched = 0
        while (headerBytes.size < MAX_HEADER_BYTES) {
            val next = input.read()
            if (next < 0) {
                return null
            }
            headerBytes.add(next.toByte())
            matched = if (next == HEADER_END[matched].toInt()) matched + 1 else 0
            if (matched == HEADER_END.size) {
                break
            }
        }
        val headerText = headerBytes.toByteArray().toString(Charsets.UTF_8)
        val lines = headerText.split("\r\n")
        val parts = lines.firstOrNull()?.split(" ") ?: return null
        if (parts.size < 2) {
            return null
        }
        val headers = mutableMapOf<String, String>()
        lines.drop(1).forEach { line ->
            val index = line.indexOf(":")
            if (index > 0) {
                headers[line.substring(0, index).lowercase(Locale.US)] = line.substring(index + 1).trim()
            }
        }
        val length = headers["content-length"]?.toIntOrNull()?.coerceAtMost(MAX_BODY_BYTES) ?: 0
        val body = ByteArray(length)
        var read = 0
        while (read < length) {
            val count = input.read(body, read, length - read)
            if (count < 0) {
                break
            }
            read += count
        }
        val rawPath = parts[1]
        return HttpRequest(
            method = parts[0].uppercase(Locale.US),
            path = rawPath.substringBefore("?"),
            headers = headers,
            body = body.copyOf(read).toString(Charsets.UTF_8),
            remoteAddress = socket.inetAddress.hostAddress.orEmpty(),
        )
    }

    private fun json(status: Int, body: JSONObject, headers: List<String> = emptyList()): HttpResponse {
        return HttpResponse(status, "application/json; charset=utf-8", body.toString(), headers)
    }

    private fun html(status: Int, body: String): HttpResponse {
        return HttpResponse(status, "text/html; charset=utf-8", body)
    }

    private fun asset(path: String, contentType: String): HttpResponse {
        return runCatching {
            context.assets.open(path).bufferedReader(Charsets.UTF_8).use {
                HttpResponse(200, contentType, it.readText())
            }
        }.getOrElse {
            json(404, JSONObject().put("error", "asset_not_found"))
        }
    }

    private fun contentTypeFor(path: String): String {
        return when {
            path.endsWith(".js") -> "application/javascript; charset=utf-8"
            path.endsWith(".css") -> "text/css; charset=utf-8"
            path.endsWith(".html") -> "text/html; charset=utf-8"
            else -> "text/plain; charset=utf-8"
        }
    }

    companion object {
        private val HEADER_END = byteArrayOf(13, 10, 13, 10)
        private const val MAX_HEADER_BYTES = 16384
        private const val MAX_BODY_BYTES = 256 * 1024
        private const val SESSION_TTL_MILLIS = 12L * 60L * 60L * 1000L
        private const val LOGIN_WINDOW_MILLIS = 5L * 60L * 1000L
    }
}

private data class HttpRequest(
    val method: String,
    val path: String,
    val headers: Map<String, String>,
    val body: String,
    val remoteAddress: String,
) {
    fun jsonBody(): JSONObject {
        if (body.isBlank()) {
            return JSONObject()
        }
        return if (headers["content-type"].orEmpty().contains("application/x-www-form-urlencoded")) {
            val json = JSONObject()
            body.split("&").forEach { part ->
                val key = URLDecoder.decode(part.substringBefore("="), "UTF-8")
                val value = URLDecoder.decode(part.substringAfter("=", ""), "UTF-8")
                json.put(key, value)
            }
            json
        } else {
            runCatching { JSONObject(body) }.getOrDefault(JSONObject())
        }
    }
}

private data class HttpResponse(
    val status: Int,
    val contentType: String,
    val body: String,
    val extraHeaders: List<String> = emptyList(),
) {
    fun toHttp(): String {
        val bytes = body.toByteArray(Charsets.UTF_8)
        val statusText = when (status) {
            200 -> "OK"
            400 -> "Bad Request"
            401 -> "Unauthorized"
            404 -> "Not Found"
            429 -> "Too Many Requests"
            else -> "Error"
        }
        return buildString {
            append("HTTP/1.1 $status $statusText\r\n")
            append("Date: ${Instant.now()}\r\n")
            append("Content-Type: $contentType\r\n")
            append("Content-Length: ${bytes.size}\r\n")
            append("Connection: close\r\n")
            extraHeaders.forEach { append(it).append("\r\n") }
            append("\r\n")
            append(body)
        }
    }
}
