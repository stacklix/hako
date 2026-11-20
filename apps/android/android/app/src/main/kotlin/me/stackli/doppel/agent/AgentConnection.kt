package me.stackli.doppel.agent

import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.io.Closeable
import java.net.ConnectException
import java.net.SocketTimeoutException
import java.net.UnknownHostException
import javax.net.ssl.SSLException
import java.util.Base64
import java.util.concurrent.Future
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.min
import kotlin.random.Random

internal class AgentConnection(
    private val settings: AgentSettings,
    private val keyId: String,
    private val sign: (ByteArray) -> String,
    private val commands: AgentCommands,
    private val state: (String, String, String?) -> Unit,
    private val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS).readTimeout(0, TimeUnit.SECONDS)
        .callTimeout(10, TimeUnit.SECONDS).followRedirects(false).followSslRedirects(false).build(),
    private val handshakeTimeoutSeconds: Long = 10,
) : Closeable {
    private val control = ScheduledThreadPoolExecutor(1).apply { removeOnCancelPolicy = true }
    private val workers = agentCommandWorkers()
    @Volatile private var closed = false
    @Volatile private var epoch = 0L
    @Volatile private var socket: WebSocket? = null
    private var phase = "disconnected"
    private var attempt = 0
    private var watchdog: Future<*>? = null
    private var reconnect: Future<*>? = null
    private var telemetry: Future<*>? = null
    private var lastMessage = System.nanoTime()
    private val activeRequests = mutableMapOf<String, Pair<Future<*>, Future<*>>>()

    fun start() { dispatch { connect() } }

    private fun dispatch(task: () -> Unit) {
        if (closed) return
        try {
            control.execute {
                if (!closed) try { task() }
                catch (error: AgentError) {
                    disconnect()
                    status("authentication_failed", error.message)
                }
                catch (error: Exception) { retry(failureMessage(error)) }
            }
        } catch (_: RejectedExecutionException) { }
    }

    private fun status(value: String, message: String, agentId: String? = null) {
        phase = value
        state(value, message, agentId)
    }

    private fun connect() {
        if (closed) return
        status("connecting", "正在检查 Sora 服务端版本")
        try {
            client.newCall(Request.Builder().url(settings.server + "/api/v1/version").build()).execute().use { response ->
                val body = response.body ?: throw IllegalStateException()
                val source = body.source()
                source.request(8193)
                if (!response.isSuccessful || source.buffer.size > 8192) throw IllegalStateException()
                val metadata = JSONObject(source.readUtf8())
                if (!AgentProtocol.compatibleServer(metadata.optString("serverVersion"))) {
                    status("version_mismatch", "需要 Sora 服务端 0.8.x；30 秒后自动检查")
                    reconnect = control.schedule({ if (!closed) connect() }, 30, TimeUnit.SECONDS)
                    return
                }
            }
            if (closed) return
            status("connecting", "正在连接 Sora")
            val currentEpoch = ++epoch
            val url = "wss://" + settings.server.removePrefix("https://") + "/ws/agent"
            val listener = object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) = dispatch {
                    if (currentEpoch != epoch) { webSocket.cancel(); return@dispatch }
                    socket = webSocket
                    status("authenticating", "正在验证设备身份")
                    send(JSONObject().put("type", "hello").put("version", AgentProtocol.VERSION)
                        .put("username", settings.username).put("keyId", keyId).put("capabilities", AgentProtocol.manifest()))
                    armWatchdog(10, currentEpoch)
                }
                override fun onMessage(webSocket: WebSocket, text: String) = dispatch {
                    if (currentEpoch != epoch) return@dispatch
                    try {
                        if (text.toByteArray(Charsets.UTF_8).size > AgentProtocol.MAX_BYTES) throw IllegalStateException()
                        val message = JSONObject(text)
                        lastMessage = System.nanoTime()
                        message(message, currentEpoch)
                    } catch (e: AgentError) {
                        disconnect()
                        status("authentication_failed", e.message)
                    } catch (_: Exception) { retry("连接消息无效，等待重连") }
                }
                override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) = dispatch {
                    if (currentEpoch == epoch) retry(response?.let { "WebSocket 握手失败（HTTP ${it.code}），等待重连" }
                        ?: failureMessage(t))
                }
                override fun onClosed(webSocket: WebSocket, code: Int, reason: String) = dispatch {
                    if (currentEpoch != epoch) return@dispatch
                    if (code == 1008) {
                        disconnect()
                        status("authentication_failed", "认证失败，请核对账号和已登记公钥，再保存配置重连")
                    } else retry("连接已断开，等待重连")
                }
                override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, null) }
            }
            // WebSocket has no total call timeout after upgrade. Its HTTP opening
            // handshake must also be bounded before onOpen is delivered.
            armWatchdog(handshakeTimeoutSeconds, currentEpoch)
            socket = client.newWebSocket(Request.Builder().url(url).build(), listener)
        } catch (error: Exception) { retry(failureMessage(error)) }
    }

    private fun message(message: JSONObject, currentEpoch: Long) {
        when {
            phase == "authenticating" && message.optString("type") == "challenge" -> {
                val payload = Base64.getDecoder().decode(message.getString("payload"))
                AgentProtocol.checkChallenge(payload, settings.server, settings.username, keyId)
                send(JSONObject().put("type", "authenticate").put("signature", sign(payload)))
                phase = "awaiting_ack"
                state("authenticating", "设备签名已提交，等待 Sora 确认", null)
            }
            phase == "awaiting_ack" && message.optString("type") == "authenticated" -> {
                val agentId = AgentProtocol.string(message, "agentId", 128)
                attempt = 0
                status("connected", "已连接 Sora", agentId)
                armWatchdog(65, currentEpoch)
            }
            phase != "connected" -> throw AgentError("authentication_failed", "服务端认证响应无效")
            message.optString("type") == "ping" -> send(JSONObject().put("type", "pong"))
            message.optString("type") == "request" -> execute(message, currentEpoch)
            message.optString("type") == "telemetry_start" -> startTelemetry(message, currentEpoch)
            message.optString("type") == "telemetry_stop" -> {
                if (message.optString("id") == telemetryId) stopTelemetry()
            }
            else -> throw IllegalStateException("Unsupported transport message")
        }
    }

    private fun armWatchdog(seconds: Long, currentEpoch: Long) {
        watchdog?.cancel(false)
        watchdog = control.schedule({
            if (closed || currentEpoch != epoch) return@schedule
            if (phase != "connected" || TimeUnit.NANOSECONDS.toSeconds(System.nanoTime() - lastMessage) >= 60) {
                retry(when (phase) {
                    "connecting" -> "WebSocket 握手超时（${seconds} 秒），等待重连"
                    "authenticating", "awaiting_ack" -> "设备认证超时，等待重连"
                    else -> "服务端心跳超时，等待重连"
                })
            } else armWatchdog(5, currentEpoch)
        }, seconds, TimeUnit.SECONDS)
    }

    private fun failureMessage(error: Throwable): String = when (error) {
        is UnknownHostException -> "无法解析 Sora 服务器地址，等待重连"
        is SSLException -> "Sora TLS 连接失败，请检查证书和手机时间；等待重连"
        is SocketTimeoutException -> "Sora 网络请求超时，等待重连"
        is ConnectException -> "无法建立 Sora 网络连接，等待重连"
        else -> "Sora 连接失败（${error.javaClass.simpleName}），等待重连"
    }

    private fun execute(message: JSONObject, currentEpoch: Long) {
        val id = message.opt("id") as? String ?: throw IllegalStateException()
        try {
            val (method, version, params) = AgentProtocol.request(message)
            if (activeRequests.containsKey(id)) throw AgentError("duplicate_request", "请求 ID 正在执行")
            val finished = AtomicBoolean(false)
            val task = workers.submit task@ {
                if (closed || currentEpoch != epoch || Thread.currentThread().isInterrupted) return@task
                val response = JSONObject().put("type", "response").put("id", id)
                try { response.put("result", commands.invoke(method, version, params)) }
                catch (e: AgentError) { response.put("error", AgentProtocol.error(e)) }
                catch (_: SecurityException) { response.put("error", AgentProtocol.error(AgentError("permission_denied", "请检查手机上的系统权限"))) }
                catch (_: Exception) { response.put("error", AgentProtocol.error(AgentError("execution_failed", "设备执行失败，请在手机上检查"))) }
                dispatch {
                    if (currentEpoch == epoch && finished.compareAndSet(false, true)) {
                        activeRequests.remove(id)?.second?.cancel(false)
                        sendBounded(response)
                    }
                }
            }
            val deadline = control.schedule({
                if (currentEpoch == epoch && finished.compareAndSet(false, true)) {
                    activeRequests.remove(id)?.first?.cancel(true)
                    workers.purge()
                    send(JSONObject().put("type", "response").put("id", id)
                        .put("error", AgentProtocol.error(AgentError("execution_timeout", "设备执行超时；操作请使用原 requestId 查询结果，不要自动重发"))))
                }
            }, 8, TimeUnit.SECONDS)
            activeRequests[id] = task to deadline
        } catch (_: RejectedExecutionException) {
            send(JSONObject().put("type", "response").put("id", id)
                .put("error", AgentProtocol.error(AgentError("agent_busy", "设备繁忙，请稍后重试"))))
        } catch (e: AgentError) {
            send(JSONObject().put("type", "response").put("id", id).put("error", AgentProtocol.error(e)))
        }
    }

    private var telemetryId: String? = null
    private var collecting = false
    private var telemetryWork: Future<*>? = null
    private fun startTelemetry(message: JSONObject, currentEpoch: Long) {
        stopTelemetry()
        val id = AgentProtocol.string(message, "id", 128)
        telemetryId = id
        telemetry = control.scheduleWithFixedDelay({
            if (closed || currentEpoch != epoch || collecting) return@scheduleWithFixedDelay
            collecting = true
            try {
                telemetryWork = workers.submit {
                    if (closed || currentEpoch != epoch || Thread.currentThread().isInterrupted) return@submit
                    val updates = AgentProtocol.capabilities.filter { it.aggregate }.map { capability ->
                        if (closed || currentEpoch != epoch || Thread.currentThread().isInterrupted) return@submit
                        val item = JSONObject().put("type", "telemetry_update").put("id", id)
                            .put("method", capability.name).put("version", 1)
                        try { item.put("result", commands.invoke(capability.name, 1, JSONObject())) }
                        catch (e: AgentError) { item.put("error", AgentProtocol.error(e)) }
                        catch (_: Exception) { item.put("error", AgentProtocol.error(AgentError("query_failed", "状态读取失败"))) }
                        item
                    }
                    dispatch {
                        if (currentEpoch == epoch && telemetryId == id) {
                            collecting = false
                            updates.forEach(::sendBounded)
                        }
                    }
                }
            } catch (_: RejectedExecutionException) { collecting = false }
        }, 0, 10, TimeUnit.SECONDS)
    }

    private fun stopTelemetry() {
        telemetry?.cancel(false); telemetry = null; telemetryId = null
        telemetryWork?.cancel(true); telemetryWork = null
        collecting = false
        workers.purge()
    }

    private fun sendBounded(value: JSONObject) {
        if (value.toString().toByteArray(Charsets.UTF_8).size > AgentProtocol.MAX_BYTES) {
            value.remove("result")
            value.put("error", AgentProtocol.error(AgentError("result_too_large", "结果超过 64 KiB，请减小分页 limit")))
        }
        send(value)
    }

    private fun send(value: JSONObject) {
        if (socket?.send(value.toString()) != true) throw IllegalStateException("WebSocket send failed")
    }

    private fun disconnect() {
        ++epoch
        activeRequests.values.forEach { (task, deadline) -> task.cancel(true); deadline.cancel(false) }
        activeRequests.clear()
        collecting = false
        stopTelemetry()
        watchdog?.cancel(false)
        watchdog = null
        socket?.cancel()
        socket = null
    }

    private fun retry(message: String) {
        if (closed) return
        disconnect()
        status("retrying", message)
        attempt = min(attempt + 1, 5)
        reconnect?.cancel(false)
        reconnect = control.schedule({ if (!closed) connect() }, (1L shl attempt) + Random.nextLong(2), TimeUnit.SECONDS)
    }

    override fun close() {
        closed = true
        ++epoch
        socket?.cancel()
        reconnect?.cancel(false)
        watchdog?.cancel(false)
        telemetry?.cancel(false)
        control.shutdownNow()
        workers.shutdownNow()
        client.dispatcher.cancelAll()
        client.dispatcher.executorService.shutdown()
        client.connectionPool.evictAll()
    }
}
