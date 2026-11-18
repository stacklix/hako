package me.stackli.doppel

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.util.Log

class RemoteControlService : Service() {
    private var server: RemoteHttpServer? = null
    private var runningConfig: RemoteControlConfig? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopRemoteServer()
            stopSelf()
            return START_NOT_STICKY
        }
        startFromConfig()
        return START_STICKY
    }

    override fun onDestroy() {
        stopRemoteServer()
        super.onDestroy()
    }

    private fun startFromConfig() {
        val config = RemoteControlStore.readRemoteConfig(this)
        if (!config.enabled || config.password.isBlank()) {
            stopRemoteServer()
            stopSelf()
            return
        }
        startForeground(NOTIFICATION_ID, notification(config.port))
        if (runningConfig == config && server?.isRunning == true) {
            return
        }
        stopRemoteServer()
        val nextServer = RemoteHttpServer(applicationContext, config)
        nextServer.start()
        server = nextServer
        runningConfig = config
        updateRuntimeStatus(isRunning = true, port = config.port)
        SmsPipeline.appendBusinessEvent(this, "远程 HTTP 控制已启动：端口 ${config.port}")
    }

    private fun stopRemoteServer() {
        server?.stop()
        server = null
        runningConfig = null
        updateRuntimeStatus(isRunning = false, port = null)
    }

    private fun notification(port: Int): Notification {
        ensureChannel()
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(android.R.drawable.stat_sys_upload_done)
            .setContentTitle("Doppel 远程控制运行中")
            .setContentText("正在监听 HTTP 端口 $port")
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "远程控制",
            NotificationManager.IMPORTANCE_LOW,
        )
        manager.createNotificationChannel(channel)
    }

    companion object {
        private const val ACTION_STOP = "me.stackli.doppel.action.REMOTE_CONTROL_STOP"
        private const val CHANNEL_ID = "doppel_remote_control"
        private const val NOTIFICATION_ID = 7318
        private const val SERVICE_TAG = "DoppelRemoteService"
        @Volatile
        private var runtimeIsRunning = false
        @Volatile
        private var runtimePort: Int? = null

        fun isRemoteServerRunning(): Boolean = runtimeIsRunning

        fun remoteServerPort(): Int? = runtimePort

        private fun updateRuntimeStatus(isRunning: Boolean, port: Int?) {
            runtimeIsRunning = isRunning
            runtimePort = port
        }

        fun sync(context: Context) {
            val config = RemoteControlStore.readRemoteConfig(context)
            val intent = Intent(context, RemoteControlService::class.java)
            if (!config.enabled || config.password.isBlank()) {
                Log.i(
                    SERVICE_TAG,
                    "远程 HTTP 控制未启动：enabled=${config.enabled} passwordConfigured=${config.password.isNotBlank()}",
                )
                context.stopService(intent)
                return
            }
            runCatching {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                Log.i(SERVICE_TAG, "远程 HTTP 控制服务启动请求已提交：port=${config.port}")
            }.onFailure {
                Log.e(SERVICE_TAG, "远程 HTTP 控制服务启动请求失败：${it.message.orEmpty()}", it)
                SmsPipeline.appendBusinessEvent(context, "远程 HTTP 控制启动失败：${it.message.orEmpty()}")
            }
        }
    }
}
