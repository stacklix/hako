package me.stackli.doppel.agent

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import me.stackli.doppel.ACTION_DOPPEL_SNAPSHOT_CHANGED
import me.stackli.doppel.MainActivity
import org.json.JSONObject
import org.json.JSONArray
import java.time.Instant
import java.util.UUID

internal object AgentRuntime {
    fun snapshot(context: Context): JSONObject = try {
        val value = AgentSettingsStore.readFile(context, "hako-agent-status.json")
        if (!value.has("state")) value.put("state", "disconnected").put("message", "未连接") else value
    } catch (_: Exception) { JSONObject().put("state", "disconnected").put("message", "未连接") }
    fun update(context: Context, state: String, message: String, agentId: String? = null) {
        val timestamp = Instant.now().toString()
        Log.i("NamiAgent", "state=$state $message")
        runCatching {
            AgentSettingsStore.updateFile(context, "hako-agent-status.json") { previous ->
                val events = previous.optJSONArray("events") ?: JSONArray()
                if (previous.optString("state") != state || previous.optString("message") != message) {
                    events.put(JSONObject().put("id", UUID.randomUUID().toString()).put("type", "agent_connection")
                        .put("state", state).put("detail", message).put("timestamp", timestamp))
                }
                val recent = JSONArray()
                for (index in maxOf(0, events.length() - 100) until events.length()) recent.put(events.getJSONObject(index))
                JSONObject().put("state", state).put("message", message)
                    .put("agentId", agentId ?: JSONObject.NULL).put("updatedAt", timestamp).put("events", recent)
            }
        }.onFailure { Log.e("NamiAgent", "Cannot persist connection status: ${it.javaClass.simpleName}") }
        context.sendBroadcast(Intent(ACTION_DOPPEL_SNAPSHOT_CHANGED).setPackage(context.packageName))
    }
}

class AgentService : Service() {
    private var connection: AgentConnection? = null
    private var channel: AgentLocalChannel? = null
    private var lan: AgentLanServer? = null
    private var currentSettings: AgentSettings? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val settings = try { AgentSettingsStore(this).read() } catch (_: Exception) {
            AgentRuntime.update(this, "configuration_error", "无法读取 Agent 配置，请打开设置检查")
            stopSelf()
            return START_NOT_STICKY
        }
        if (!settings.enabled) { stopSelf(); return START_NOT_STICKY }
        val manager = requireNotNull(getSystemService(NotificationManager::class.java))
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Nami Agent", NotificationManager.IMPORTANCE_LOW))
        startForeground(NOTIFICATION, notification("正在连接 Sora"))
        if (currentSettings == settings && connection != null && intent?.getBooleanExtra("restart", false) != true) return START_STICKY
        connection?.close()
        lan?.close()
        lan = null
        channel?.close()
        currentSettings = settings
        try {
            val id = AgentKeys.keyId() ?: throw AgentError("key_missing", "设备密钥不存在，请重新生成并登记")
            AgentProtocol.origin(settings.server)
            val local = AgentLocalChannel(applicationContext).also { channel = it }
            val dispatcher = AgentGuardianCommands(local)
            // LAN failure must not interrupt the cloud connection.
            lan = runCatching { AgentLanServer(applicationContext, dispatcher) }.getOrNull()
            connection = AgentConnection(settings, id, AgentKeys::sign, dispatcher,
                { state, message, agentId ->
                    AgentRuntime.update(applicationContext, state, message, agentId)
                    mainHandler.post { if (connection != null) manager.notify(NOTIFICATION, notification(message)) }
                }).also { it.start() }
        } catch (_: Exception) {
            AgentRuntime.update(this, "configuration_error", "Agent 配置或设备密钥无效，请在设置中检查")
            stopSelf()
            return START_NOT_STICKY
        }
        return START_STICKY
    }

    private fun notification(message: String): Notification {
        val pending = PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL).setSmallIcon(android.R.drawable.stat_notify_sync)
            .setContentTitle("Nami Agent").setContentText(message)
            .setContentIntent(pending).setOngoing(true).build()
    }

    override fun onDestroy() {
        connection?.close()
        connection = null
        lan?.close()
        lan = null
        channel?.close()
        channel = null
        mainHandler.removeCallbacksAndMessages(null)
        AgentRuntime.update(this, "disconnected", "Agent 已停止")
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "hako_agent"
        private const val NOTIFICATION = 7319
        fun sync(context: Context, restart: Boolean = false) {
            val intent = Intent(context, AgentService::class.java).putExtra("restart", restart)
            try {
                if (!AgentSettingsStore(context).read().enabled) { context.stopService(intent); return }
                context.startForegroundService(intent)
            }
            catch (_: Exception) {
                AgentRuntime.update(context, "start_blocked", "系统暂不允许后台启动，请打开 Nami 后重试")
            }
        }
    }
}
