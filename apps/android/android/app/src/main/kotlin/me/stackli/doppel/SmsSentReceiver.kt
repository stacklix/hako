package me.stackli.doppel

import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.telephony.SmsManager

class SmsSentReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_DOPPEL_SMS_SENT) {
            return
        }

        val target = intent.getStringExtra(EXTRA_SMS_TARGET).orEmpty()
        val source = intent.getStringExtra(EXTRA_SMS_SOURCE).orEmpty()
        val message = when (resultCode) {
            Activity.RESULT_OK -> "短信发送成功：$target"
            SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "短信发送失败：$target，通用失败"
            SmsManager.RESULT_ERROR_NO_SERVICE -> "短信发送失败：$target，无蜂窝服务"
            SmsManager.RESULT_ERROR_NULL_PDU -> "短信发送失败：$target，短信 PDU 为空"
            SmsManager.RESULT_ERROR_RADIO_OFF -> "短信发送失败：$target，飞行模式或无线电关闭"
            else -> "短信发送失败：$target，系统结果码 $resultCode"
        }
        val detail = if (source.isBlank()) message else "$message，原短信来自 $source"
        SmsPipeline.appendBusinessEvent(context, detail)
    }
}
