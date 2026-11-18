package me.stackli.doppel

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager

class PhoneStateReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != TelephonyManager.ACTION_PHONE_STATE_CHANGED) {
            return
        }

        val state = intent.getStringExtra(TelephonyManager.EXTRA_STATE)
        if (state != TelephonyManager.EXTRA_STATE_RINGING) {
            return
        }

        val incomingNumber = intent.getStringExtra(TelephonyManager.EXTRA_INCOMING_NUMBER)
        val subscriptionId = subscriptionIdFromIntent(context, intent)
        SmsPipeline.enqueueIncomingCall(context, incomingNumber.orEmpty(), subscriptionId)
    }

    private fun subscriptionIdFromIntent(context: Context, intent: Intent): Int {
        val directSubscriptionId = listOf(
            "subscription",
            "subscription_id",
            "android.telephony.extra.SUBSCRIPTION_INDEX",
            "android.telephony.extra.SUBSCRIPTION_ID",
        ).firstNotNullOfOrNull { key ->
            intent.getIntExtra(key, -1).takeIf { it >= 0 }
        }
        if (directSubscriptionId != null) {
            return directSubscriptionId
        }

        val slotIndex = listOf(
            "slot",
            "simSlot",
            "phone",
            "android.telephony.extra.SLOT_INDEX",
        ).firstNotNullOfOrNull { key ->
            intent.getIntExtra(key, -1).takeIf { it >= 0 }
        } ?: return -1

        val manager = context.getSystemService(SubscriptionManager::class.java)
        return runCatching {
            manager.activeSubscriptionInfoList
                .orEmpty()
                .firstOrNull { it.simSlotIndex == slotIndex }
                ?.subscriptionId
        }.getOrNull() ?: -1
    }
}
