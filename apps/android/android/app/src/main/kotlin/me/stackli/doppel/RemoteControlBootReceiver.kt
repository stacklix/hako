package me.stackli.doppel

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import me.stackli.doppel.agent.AgentService

class RemoteControlBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action.orEmpty()
        if (action !in SUPPORTED_ACTIONS) {
            return
        }
        Log.i(RECEIVER_TAG, "收到远程 HTTP 控制启动广播：$action")
        runCatching {
            if (SmsPipeline.isUserUnlocked(context)) {
                RemoteControlStore.syncDirectBootConfig(context)
                AgentService.sync(context)
            }
            if (action == Intent.ACTION_USER_UNLOCKED) {
                SmsPipeline.backfillMissedIncomingSmsAfterUnlock(context)
            }
            RemoteControlService.sync(context)
        }.onFailure {
            Log.e(RECEIVER_TAG, "远程 HTTP 控制开机启动失败：${it.message.orEmpty()}", it)
            SmsPipeline.appendBusinessEvent(context, "远程 HTTP 控制开机启动失败：${it.message.orEmpty()}")
        }
    }

    companion object {
        private const val RECEIVER_TAG = "NamiRemoteBoot"
        private val SUPPORTED_ACTIONS = setOf(
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_LOCKED_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_USER_UNLOCKED,
            "android.intent.action.QUICKBOOT_POWERON",
            "com.htc.intent.action.QUICKBOOT_POWERON",
        )
    }
}
