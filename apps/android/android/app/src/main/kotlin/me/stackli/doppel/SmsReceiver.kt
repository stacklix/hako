package me.stackli.doppel

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.provider.Telephony
import android.util.Log

class SmsReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Telephony.Sms.Intents.SMS_RECEIVED_ACTION) {
            Log.i(RECEIVER_TAG, "忽略非短信广播：${intent.action.orEmpty()}")
            return
        }

        val messages = Telephony.Sms.Intents.getMessagesFromIntent(intent)
        if (messages.isEmpty()) {
            Log.i(RECEIVER_TAG, "收到短信广播，但消息列表为空")
            return
        }

        val sender = messages.firstOrNull()?.originatingAddress.orEmpty()
        val body = messages.joinToString(separator = "") { it.messageBody.orEmpty() }
        val subscriptionId = listOf(
            "subscription",
            "android.telephony.extra.SUBSCRIPTION_INDEX",
            "android.telephony.extra.SUBSCRIPTION_ID",
        ).firstNotNullOfOrNull { key ->
            intent.getIntExtra(key, -1).takeIf { it >= 0 }
        } ?: -1
        Log.i(
            RECEIVER_TAG,
            "收到短信广播：from=$sender parts=${messages.size} bodyLength=${body.length} subscriptionId=$subscriptionId",
        )
        if (!SmsPipeline.isUserUnlocked(context)) {
            val pendingResult = goAsync()
            Thread {
                try {
                    SmsPipeline.processIncomingSms(context.applicationContext, sender, body, subscriptionId)
                } finally {
                    pendingResult.finish()
                }
            }.start()
            return
        }
        SmsPipeline.enqueueIncomingSms(context, sender, body, subscriptionId)
    }

    companion object {
        private const val RECEIVER_TAG = "DoppelSms"
    }
}
