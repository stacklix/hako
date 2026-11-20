package me.stackli.doppel.agent

import android.app.Service
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Message
import android.os.Messenger
import android.os.Process
import org.json.JSONObject
import java.io.Closeable
import java.util.UUID
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

// Android's private Binder channel is the equivalent of the Windows per-user local pipe.
// The guardian never executes query/action business code or replays an interrupted request.
internal class AgentLocalChannel(private val context: Context) : AgentCommands, Closeable {
    private val thread = HandlerThread("hako-agent-replies").apply { start() }
    private val pending = ConcurrentHashMap<String, CompletableFuture<JSONObject>>()
    @Volatile private var remote: Messenger? = null
    @Volatile private var closed = false
    private var bound = false
    private val replies = Messenger(Handler(thread.looper) { message ->
        if (message.sendingUid != Process.myUid()) return@Handler true
        val id = message.data.getString("id") ?: return@Handler true
        val future = pending.remove(id) ?: return@Handler true
        try {
            val raw = message.data.getString("payload") ?: throw IllegalStateException()
            future.complete(JSONObject(raw))
        } catch (_: Exception) {
            future.completeExceptionally(AgentError("main_process_unavailable", "主进程返回无效数据"))
        }
        true
    })
    private val binding = object : ServiceConnection {
        override fun onServiceConnected(name: ComponentName, service: IBinder) { remote = Messenger(service) }
        override fun onServiceDisconnected(name: ComponentName) {
            remote = null
            failPending()
            // Android reconnects this existing binding when the business process returns.
        }
        override fun onBindingDied(name: ComponentName) {
            remote = null
            failPending()
            if (bound) { context.unbindService(this); bound = false }
        }
    }

    init {
        try {
            bound = context.bindService(Intent(context, AgentCommandService::class.java), binding, Context.BIND_AUTO_CREATE)
        } catch (error: Exception) {
            thread.quitSafely()
            throw error
        }
    }

    override fun invoke(method: String, version: Int, params: JSONObject): JSONObject {
        val peer = remote
        if (closed || peer == null) throw AgentError("main_process_unavailable", "设备业务进程尚未就绪，请稍后手动重试")
        val id = UUID.randomUUID().toString()
        val future = CompletableFuture<JSONObject>()
        pending[id] = future
        try {
            val message = Message.obtain().apply {
                replyTo = replies
                data = Bundle().apply {
                    putString("id", id)
                    putString("payload", JSONObject().put("method", method).put("version", version).put("params", params).toString())
                }
            }
            peer.send(message)
            val response = future.get(8, TimeUnit.SECONDS)
            val error = response.optJSONObject("error")
            if (error != null) throw AgentError(error.getString("code"), error.getString("message"))
            return response.getJSONObject("result")
        } catch (error: AgentError) { throw error }
        catch (_: Exception) {
            throw AgentError("main_process_unavailable", "本机调用未确认完成；操作请用原 requestId 查询结果，不要自动重发")
        } finally { pending.remove(id) }
    }

    private fun failPending() {
        pending.values.forEach { it.completeExceptionally(AgentError("main_process_unavailable", "设备业务进程已断开")) }
        pending.clear()
    }

    override fun close() {
        closed = true
        remote = null
        failPending()
        if (bound) { context.unbindService(binding); bound = false }
        thread.quitSafely()
    }
}

class AgentCommandService : Service() {
    private val thread = HandlerThread("hako-agent-commands").apply { start() }
    private val workers = ThreadPoolExecutor(0, 4, 30, TimeUnit.SECONDS, SynchronousQueue())
    private lateinit var commands: AgentDispatcher
    private lateinit var messenger: Messenger

    override fun onCreate() {
        super.onCreate()
        commands = AgentDispatcher(applicationContext)
        messenger = Messenger(Handler(thread.looper) { message ->
            if (message.sendingUid != Process.myUid()) return@Handler true
            val id = message.data.getString("id") ?: return@Handler true
            val reply = message.replyTo ?: return@Handler true
            val raw = message.data.getString("payload") ?: return@Handler true
            try {
                workers.execute {
                    val response = JSONObject()
                    try {
                        if (raw.toByteArray(Charsets.UTF_8).size > AgentProtocol.MAX_BYTES) AgentProtocol.invalid("请求过大")
                        val request = JSONObject(raw)
                        response.put("result", commands.invoke(request.getString("method"), request.getInt("version"), request.getJSONObject("params")))
                        if (response.toString().toByteArray(Charsets.UTF_8).size > AgentProtocol.MAX_BYTES) {
                            throw AgentError("result_too_large", "结果超过 64 KiB，请减小分页 limit")
                        }
                    } catch (error: AgentError) { response.remove("result"); response.put("error", AgentProtocol.error(error)) }
                    catch (_: Exception) { response.put("error", AgentProtocol.error(AgentError("execution_failed", "设备业务执行失败，请在手机上检查权限和配置"))) }
                    sendReply(reply, id, response)
                }
            } catch (_: RejectedExecutionException) {
                sendReply(reply, id, JSONObject().put("error", AgentProtocol.error(AgentError("agent_busy", "设备业务进程繁忙"))))
            }
            true
        })
    }

    private fun sendReply(peer: Messenger, id: String, response: JSONObject) {
        try {
            peer.send(Message.obtain().apply { data = Bundle().apply {
                putString("id", id); putString("payload", response.toString())
            } })
        } catch (_: Exception) { /* A lost caller never causes an operation to be replayed. */ }
    }

    override fun onBind(intent: Intent?): IBinder = messenger.binder

    override fun onDestroy() {
        workers.shutdownNow()
        thread.quitSafely()
        super.onDestroy()
    }
}
