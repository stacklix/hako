package me.stackli.doppel

import android.Manifest
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.UserManager
import android.provider.CallLog
import android.provider.Telephony
import android.telecom.PhoneAccountHandle
import android.telecom.TelecomManager
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import android.util.Base64
import android.util.Log
import androidx.work.Data
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.Socket
import java.net.URL
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import javax.net.ssl.SSLSocketFactory

private const val PIPELINE_TAG = "NamiSms"
private const val PREFS_NAME = "doppel"
private const val DIRECT_BOOT_PREFS_NAME = "doppel_direct_boot"
private const val KEY_CONFIG = "config_json"
private const val KEY_EVENTS = "events_json"
private const val KEY_LAST_SMS_SIGNATURE = "last_sms_signature"
private const val KEY_LAST_SMS_TIMESTAMP = "last_sms_timestamp"
private const val KEY_LAST_CALL_SIGNATURE = "last_call_signature"
private const val KEY_LAST_CALL_TIMESTAMP = "last_call_timestamp"
private const val KEY_LAST_BACKFILL_SMS_DATE = "last_backfill_sms_date"
private const val DUPLICATE_SMS_WINDOW_MILLIS = 5000L
private const val DUPLICATE_CALL_WINDOW_MILLIS = 10000L
private const val BACKFILL_LOOKBACK_MILLIS = 30L * 60L * 1000L
private const val MAX_BACKFILL_SMS_COUNT = 20

internal object SmsPipeline {
    const val INPUT_SENDER = "sender"
    const val INPUT_BODY = "body"
    const val INPUT_SUBSCRIPTION_ID = "subscription_id"
    const val INPUT_CALLER = "caller"

    fun isUserUnlocked(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.getSystemService(UserManager::class.java)?.isUserUnlocked != false
        } else {
            true
        }
    }

    fun enqueueIncomingSms(context: Context, sender: String, body: String, subscriptionId: Int = -1) {
        if (isDuplicateIncomingSms(context, sender, body)) {
            appendDebugEvent(context, "忽略重复短信广播：来自 $sender 的同一条短信已进入处理队列")
            return
        }
        val request = OneTimeWorkRequestBuilder<SmsProcessingWorker>()
            .setInputData(
                Data.Builder()
                    .putString(INPUT_SENDER, sender)
                    .putString(INPUT_BODY, body)
                    .putInt(INPUT_SUBSCRIPTION_ID, subscriptionId)
                    .build(),
            ).build()
        WorkManager.getInstance(context).enqueue(request)
        appendDebugEvent(context, "收到短信广播，已加入后台任务队列")
    }

    fun enqueueIncomingCall(context: Context, caller: String, subscriptionId: Int = -1) {
        val request = OneTimeWorkRequestBuilder<CallProcessingWorker>()
            .setInputData(
                Data.Builder()
                    .putString(INPUT_CALLER, caller)
                    .putInt(INPUT_SUBSCRIPTION_ID, subscriptionId)
                    .build(),
            ).build()
        WorkManager.getInstance(context).enqueue(request)
        appendDebugEvent(context, "收到来电广播，已加入后台任务队列")
    }

    private fun isDuplicateIncomingSms(context: Context, sender: String, body: String): Boolean {
        val signature = "$sender:${body.hashCode()}"
        val now = System.currentTimeMillis()
        val prefs = pipelinePrefs(context)
        val lastSignature = prefs.getString(KEY_LAST_SMS_SIGNATURE, "").orEmpty()
        val lastTimestamp = prefs.getLong(KEY_LAST_SMS_TIMESTAMP, 0L)
        prefs.edit()
            .putString(KEY_LAST_SMS_SIGNATURE, signature)
            .putLong(KEY_LAST_SMS_TIMESTAMP, now)
            .apply()
        return signature == lastSignature && now - lastTimestamp <= DUPLICATE_SMS_WINDOW_MILLIS
    }

    fun processIncomingSms(context: Context, sender: String, body: String, subscriptionId: Int = -1) {
        markIncomingSmsSeen(context, System.currentTimeMillis())
        appendDebugEvent(context, "后台任务开始处理来自 $sender 的短信，内容长度 ${body.length}")
        val config = readConfig(context)
        val localRecipient = localRecipientLabel(context, subscriptionId)
        appendDebugEvent(context, configSummary(config))
        val command = parseCommand(body)
        val isTrusted = isTrustedSender(config, sender)
        appendDebugEvent(
            context,
            if (command == null) {
                "短信不是 Nami 指令，进入普通短信转发流程"
            } else if (isTrusted) {
                "识别到白名单短信指令，进入指令流程"
            } else {
                "识别到指令格式但发送方不在白名单，按普通短信处理"
            },
        )

        if (command != null && isTrusted) {
            appendEvent(
                context,
                "sms_command",
                "来自 $sender 的短信指令",
                JSONObject()
                    .put("from", sender)
                    .put("to", localRecipient)
                    .put("commandType", command.label)
                    .put("commandContent", body),
            )
            executeCommand(context, config, command, sender)
            return
        }

        appendEvent(
            context,
            "sms_received",
            "来自 $sender 的普通短信",
            JSONObject()
                .put("from", sender)
                .put("to", localRecipient)
                .put("content", body),
        )
        appendForwardingTrace(
            "短信转发流程开始：from=$sender to=$localRecipient bodyLength=${body.length} ${forwardingDetectionSummary(config)}",
        )
        forwardSms(context, config, sender, localRecipient, body)
        forwardEmail(context, config, sender, localRecipient, body)
        pushHttp(context, config, sender, body)
        appendForwardingTrace("短信转发流程结束：from=$sender")
    }

    fun seedInboxBackfillCursor(context: Context) {
        if (context.checkSelfPermission(Manifest.permission.READ_SMS) != PackageManager.PERMISSION_GRANTED) {
            return
        }
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (prefs.contains(KEY_LAST_BACKFILL_SMS_DATE)) {
            return
        }
        val latestDate = latestInboxSmsDate(context) ?: System.currentTimeMillis()
        prefs.edit().putLong(KEY_LAST_BACKFILL_SMS_DATE, latestDate).apply()
        syncDirectBootBackfillCursor(context, latestDate)
        appendForwardingTrace("短信补处理游标已初始化：date=$latestDate")
    }

    fun backfillMissedIncomingSmsAfterUnlock(context: Context) {
        if (context.checkSelfPermission(Manifest.permission.READ_SMS) != PackageManager.PERMISSION_GRANTED) {
            appendDebugEvent(context, "解锁后短信补处理跳过：缺少 READ_SMS 权限")
            return
        }
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val lastDate = maxOf(
            prefs.getLong(KEY_LAST_BACKFILL_SMS_DATE, 0L),
            directBootBackfillCursor(context),
        )
        if (lastDate <= 0L) {
            seedInboxBackfillCursor(context)
            appendForwardingTrace("解锁后短信补处理跳过：游标未初始化")
            return
        }
        prefs.edit().putLong(KEY_LAST_BACKFILL_SMS_DATE, lastDate).apply()

        val since = maxOf(lastDate, System.currentTimeMillis() - BACKFILL_LOOKBACK_MILLIS)
        val missed = recentInboxSmsAfter(context, since)
        if (missed.isEmpty()) {
            appendForwardingTrace("解锁后短信补处理：未发现新短信 since=$since")
            return
        }

        val pending = missed.take(MAX_BACKFILL_SMS_COUNT)
        appendForwardingTrace("解锁后短信补处理开始：count=${pending.size} since=$since")
        pending.forEach { sms ->
            processIncomingSms(context, sms.sender, sms.body)
            markIncomingSmsSeen(context, sms.date)
        }
        appendForwardingTrace("解锁后短信补处理结束：count=${pending.size}")
    }

    fun processIncomingCall(context: Context, caller: String, subscriptionId: Int = -1) {
        val normalizedCaller = caller.ifBlank { latestIncomingCallNumber(context).ifBlank { "未知号码" } }
        if (isDuplicateIncomingCall(context, normalizedCaller)) {
            appendDebugEvent(context, "忽略重复来电广播：来自 $normalizedCaller 的来电已在短时间内处理")
            return
        }

        appendDebugEvent(context, "收到来电广播：from=$normalizedCaller subscriptionId=$subscriptionId")
        val config = readConfig(context)
        val localRecipient = localRecipientLabel(
            context,
            subscriptionId,
            fallbackToFirstSubscription = false,
            unknownLabel = "未识别接收号码",
        )
        appendEvent(
            context,
            "call_received",
            if (normalizedCaller == "未知号码") "收到未知号码来电" else "来自 $normalizedCaller 的来电",
            JSONObject()
                .put("from", normalizedCaller)
                .put("to", localRecipient),
        )
        appendDebugEvent(context, "开始来电通知转发流程")
        forwardSmsNotification(
            context = context,
            config = config,
            notificationType = "来电通知",
            from = normalizedCaller,
            to = localRecipient,
            content = "电话呼入",
            eventDetail = "来电通知",
        )
        forwardEmailNotification(
            context = context,
            config = config,
            notificationType = "来电通知",
            from = normalizedCaller,
            to = localRecipient,
            content = "",
            subject = "Nami 来电通知 from $normalizedCaller",
            eventDetail = "来电通知",
        )
    }

    fun sendRemoteSms(context: Context, target: String, message: String, selectedSim: String = ""): RemoteActionResult {
        val phone = normalizePhoneNumber(target)
        if (phone.isBlank()) {
            return RemoteActionResult(false, "手机号不能为空")
        }
        if (message.isBlank()) {
            return RemoteActionResult(false, "短信内容不能为空")
        }
        if (context.checkSelfPermission(Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
            return RemoteActionResult(false, "缺少短信发送权限")
        }
        return runCatching {
            val config = readConfig(context)
            smsManager(context, config, selectedSim).sendTextMessage(phone, null, message, null, null)
            appendEvent(
                context,
                "sms_sent_command",
                "远程 HTTP 控制发送短信到 $phone${selectedSim.ifBlank { "" }.let { if (it.isBlank()) "" else "，SIM $it" }}",
                JSONObject()
                    .put("to", phone)
                    .put("content", message)
                    .put("sim", selectedSim),
            )
            RemoteActionResult(true, "短信发送请求已提交")
        }.getOrElse {
            appendDebugEvent(context, "远程短信发送失败：${it.message.orEmpty()}")
            RemoteActionResult(false, it.message.orEmpty().ifBlank { "短信发送失败" })
        }
    }

    fun startRemoteCall(context: Context, number: String, selectedSim: String = ""): RemoteActionResult {
        val phone = normalizePhoneNumber(number)
        if (phone.isBlank()) {
            return RemoteActionResult(false, "电话号码不能为空")
        }
        if (context.checkSelfPermission(Manifest.permission.CALL_PHONE) != PackageManager.PERMISSION_GRANTED) {
            return RemoteActionResult(false, "缺少拨号权限")
        }
        return runCatching {
            if (!placeCallWithTelecomManager(context, phone, selectedSim)) {
                startCallActivity(context, phone, selectedSim)
            }
            appendEvent(
                context,
                "call_out_command",
                "远程 HTTP 控制呼出 $phone${selectedSim.ifBlank { "" }.let { if (it.isBlank()) "" else "，SIM $it" }}",
            )
            RemoteActionResult(true, "拨号请求已提交")
        }.getOrElse {
            appendDebugEvent(context, "远程拨号失败：${it.message.orEmpty()}")
            RemoteActionResult(false, it.message.orEmpty().ifBlank { "拨号失败" })
        }
    }

    fun appendDebugEvent(context: Context, detail: String) {
        if (isOperationalSummary(detail)) {
            appendBusinessEvent(context, detail)
        }
    }

    fun appendBusinessEvent(context: Context, detail: String) {
        appendEvent(context, "operation_log", detail)
    }

    private fun appendForwardingTrace(detail: String) {
        Log.i(PIPELINE_TAG, detail)
    }

    private fun isOperationalSummary(detail: String): Boolean {
        return detail.startsWith("短信发送成功") ||
            detail.startsWith("短信发送失败") ||
            detail.startsWith("邮件转发失败") ||
            detail.startsWith("来电通知失败") ||
            detail.startsWith("HTTP 转发完成") ||
            detail.startsWith("HTTP 转发失败") ||
            detail.startsWith("后台任务失败") ||
            detail.startsWith("来电后台任务失败") ||
            detail.contains("指令未执行")
    }

    private fun executeCommand(context: Context, config: JSONObject, command: SmsCommand, sender: String) {
        val commands = config.optJSONObject("commands") ?: JSONObject()
        when (command) {
            is SmsCommand.Call -> {
                if (!commands.optBoolean("callEnabled", true)) {
                    appendDebugEvent(context, "CALL 指令未执行：权限开关关闭")
                    return
                }
                if (context.checkSelfPermission(Manifest.permission.CALL_PHONE) != PackageManager.PERMISSION_GRANTED) {
                    appendDebugEvent(context, "CALL 指令未执行：缺少拨号权限")
                    return
                }
                val callNumber = normalizePhoneNumber(command.number)
                val intent = Intent(Intent.ACTION_CALL, Uri.parse("tel:$callNumber"))
                intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                context.startActivity(intent)
                appendEvent(context, "call_out_command", "根据 $sender 的指令呼出 $callNumber")
            }
            is SmsCommand.SendSms -> {
                if (!commands.optBoolean("smsEnabled", true)) {
                    appendDebugEvent(context, "SMS 指令未执行：权限开关关闭")
                    return
                }
                if (context.checkSelfPermission(Manifest.permission.SEND_SMS) != PackageManager.PERMISSION_GRANTED) {
                    appendDebugEvent(context, "SMS 指令未执行：缺少短信发送权限")
                    return
                }
                val smsNumber = normalizePhoneNumber(command.number)
                smsManager(context, config).sendTextMessage(smsNumber, null, command.message, null, null)
                appendEvent(context, "sms_sent_command", "根据 $sender 的指令发送短信到 $smsNumber")
            }
        }
    }

    private fun isDuplicateIncomingCall(context: Context, caller: String): Boolean {
        val signature = caller
        val now = System.currentTimeMillis()
        val prefs = pipelinePrefs(context)
        val lastSignature = prefs.getString(KEY_LAST_CALL_SIGNATURE, "").orEmpty()
        val lastTimestamp = prefs.getLong(KEY_LAST_CALL_TIMESTAMP, 0L)
        prefs.edit()
            .putString(KEY_LAST_CALL_SIGNATURE, signature)
            .putLong(KEY_LAST_CALL_TIMESTAMP, now)
            .apply()
        return signature == lastSignature && now - lastTimestamp <= DUPLICATE_CALL_WINDOW_MILLIS
    }

    private fun markIncomingSmsSeen(context: Context, receivedAt: Long) {
        val prefs = pipelinePrefs(context)
        val current = prefs.getLong(KEY_LAST_BACKFILL_SMS_DATE, 0L)
        if (receivedAt > current) {
            prefs.edit().putLong(KEY_LAST_BACKFILL_SMS_DATE, receivedAt).apply()
        }
        syncDirectBootBackfillCursor(context, receivedAt)
    }

    private fun syncDirectBootBackfillCursor(context: Context, receivedAt: Long) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return
        }
        val directBootPrefs = context.createDeviceProtectedStorageContext()
            .getSharedPreferences(DIRECT_BOOT_PREFS_NAME, Context.MODE_PRIVATE)
        val current = directBootPrefs.getLong(KEY_LAST_BACKFILL_SMS_DATE, 0L)
        if (receivedAt > current) {
            directBootPrefs.edit().putLong(KEY_LAST_BACKFILL_SMS_DATE, receivedAt).apply()
        }
    }

    private fun directBootBackfillCursor(context: Context): Long {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
            return 0L
        }
        return context.createDeviceProtectedStorageContext()
            .getSharedPreferences(DIRECT_BOOT_PREFS_NAME, Context.MODE_PRIVATE)
            .getLong(KEY_LAST_BACKFILL_SMS_DATE, 0L)
    }

    private fun forwardSms(
        context: Context,
        config: JSONObject,
        sender: String,
        localRecipient: String,
        body: String,
    ) {
        forwardSmsNotification(
            context = context,
            config = config,
            notificationType = "短信通知",
            from = sender,
            to = localRecipient,
            content = body,
            eventDetail = "短信转发",
        )
    }

    private fun forwardSmsNotification(
        context: Context,
        config: JSONObject,
        notificationType: String,
        from: String,
        to: String,
        content: String,
        eventDetail: String,
    ) {
        val forwarding = config.optJSONObject("forwarding") ?: JSONObject()
        val targets = forwarding.optJSONArray("smsTargets") ?: JSONArray()
        val hasPermission = context.checkSelfPermission(Manifest.permission.SEND_SMS) == PackageManager.PERMISSION_GRANTED
        appendForwardingTrace(
            "$eventDetail-短信方式检测：sendSmsPermission=$hasPermission totalTargets=${targets.length()} selectedSim=${forwarding.optString("selectedSmsSim").ifBlank { "系统默认" }}",
        )
        if (!hasPermission) {
            appendForwardingTrace("$eventDetail-短信方式跳过：缺少 SEND_SMS 权限")
            appendDebugEvent(context, "跳过$eventDetail：缺少短信发送权限")
            return
        }
        if (targets.length() == 0) {
            appendForwardingTrace("$eventDetail-短信方式跳过：没有配置手机号目标")
            return
        }
        val manager = smsManager(context, config)
        for (index in 0 until targets.length()) {
            val target = targets.optJSONObject(index) ?: continue
            val rawPhone = target.optString("value")
            val phone = normalizePhoneNumber(rawPhone)
            if (phone.isBlank()) {
                appendForwardingTrace("$eventDetail-短信目标 ${index + 1} 跳过：手机号为空")
                continue
            }
            if (phone != rawPhone) {
                appendForwardingTrace("$eventDetail-短信目标 ${index + 1} 号码规范化：$rawPhone -> $phone")
            }
            appendForwardingTrace("$eventDetail-短信目标 ${index + 1} 提交发送：target=$phone")
            runCatching {
                manager.sendTextMessage(
                    phone,
                    null,
                    forwardedSmsBody(notificationType, from, to, content),
                    sentIntent(context, from, phone),
                    null,
                )
            }.onSuccess {
                appendForwardingTrace("$eventDetail-短信目标 ${index + 1} 发送请求已提交：target=$phone")
                appendEvent(context, "sms_forwarded", "${eventDetail}请求已提交：来自 $from，到 $phone")
            }.onFailure {
                appendForwardingTrace("$eventDetail-短信目标 ${index + 1} 提交失败：target=$phone error=${it.message.orEmpty()}")
                appendDebugEvent(context, "${eventDetail}失败：$phone，${it.message.orEmpty()}")
            }
        }
    }

    private fun sentIntent(context: Context, sender: String, target: String): PendingIntent {
        val intent = Intent(ACTION_DOPPEL_SMS_SENT)
            .setPackage(context.packageName)
            .putExtra(EXTRA_SMS_SOURCE, sender)
            .putExtra(EXTRA_SMS_TARGET, target)
        val requestCode = (System.currentTimeMillis() and 0x7fffffff).toInt()
        return PendingIntent.getBroadcast(
            context,
            requestCode,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
    }

    private fun normalizePhoneNumber(value: String): String {
        val trimmed = value.trim()
        val normalized = buildString {
            trimmed.forEachIndexed { index, char ->
                when {
                    char.isDigit() -> append(char)
                    char == '+' && index == 0 -> append(char)
                }
            }
        }
        return when {
            normalized.startsWith("+86") && normalized.length == 14 -> {
                normalized.removePrefix("+86")
            }
            normalized.startsWith("0086") && normalized.length == 15 -> {
                normalized.removePrefix("0086")
            }
            else -> normalized
        }
    }

    private fun forwardedSmsBody(type: String, from: String, to: String, content: String): String {
        return "Type: $type\nFrom: $from\nTo: $to\nContent: $content\nTime: ${currentLocalTimeLabel()}"
    }

    private fun currentLocalTimeLabel(): String {
        return DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss XXX")
            .withZone(ZoneId.systemDefault())
            .format(Instant.now())
    }

    private fun pushHttp(context: Context, config: JSONObject, sender: String, body: String) {
        val forwarding = config.optJSONObject("forwarding") ?: JSONObject()
        val targets = forwarding.optJSONArray("httpTargets") ?: JSONArray()
        appendForwardingTrace(
            "短信转发-HTTP方式检测：totalTargets=${targets.length()}",
        )
        if (targets.length() == 0) {
            appendForwardingTrace("短信转发-HTTP方式跳过：没有配置 HTTP 目标")
            return
        }
        for (index in 0 until targets.length()) {
            val target = targets.optJSONObject(index) ?: continue
            val url = target.optString("value")
            if (url.isBlank()) {
                appendForwardingTrace("短信转发-HTTP目标 ${index + 1} 跳过：URL 为空")
                continue
            }

            runCatching {
                appendForwardingTrace("短信转发-HTTP目标 ${index + 1} 提交推送：url=$url")
                val connection = URL(url).openConnection() as HttpURLConnection
                connection.requestMethod = "POST"
                connection.setRequestProperty("Content-Type", "application/json; charset=utf-8")
                connection.connectTimeout = 15000
                connection.readTimeout = 15000
                connection.doOutput = true
                val payload = JSONObject()
                    .put("type", Telephony.Sms.Intents.SMS_RECEIVED_ACTION)
                    .put("from", sender)
                    .put("body", body)
                    .put("receivedAt", Instant.now().toString())
                OutputStreamWriter(connection.outputStream, Charsets.UTF_8).use {
                    it.write(payload.toString())
                }
                val responseCode = connection.responseCode
                connection.disconnect()
                appendForwardingTrace("短信转发-HTTP目标 ${index + 1} 推送完成：url=$url status=$responseCode")
                appendDebugEvent(context, "HTTP 转发完成：$url，状态码 $responseCode")
            }.onFailure {
                appendForwardingTrace("短信转发-HTTP目标 ${index + 1} 推送失败：url=$url error=${it.message.orEmpty()}")
                appendDebugEvent(context, "HTTP 转发失败：${it.message.orEmpty()}")
            }
        }
    }

    private fun forwardEmail(
        context: Context,
        config: JSONObject,
        sender: String,
        localRecipient: String,
        body: String,
    ) {
        forwardEmailNotification(
            context = context,
            config = config,
            notificationType = "短信通知",
            from = sender,
            to = localRecipient,
            content = body,
            subject = "Nami 短信通知 from $sender",
            eventDetail = "邮件转发",
        )
    }

    private fun forwardEmailNotification(
        context: Context,
        config: JSONObject,
        notificationType: String,
        from: String,
        to: String,
        content: String,
        subject: String,
        eventDetail: String,
    ) {
        val forwarding = config.optJSONObject("forwarding") ?: JSONObject()
        val smtp = forwarding.optJSONObject("smtp")
        val targets = forwarding.optJSONArray("emailTargets") ?: JSONArray()
        appendForwardingTrace(
            "$eventDetail-邮件方式检测：smtpConfigured=${smtp != null} totalTargets=${targets.length()}",
        )
        if (smtp == null) {
            appendForwardingTrace("$eventDetail-邮件方式跳过：SMTP 发件人未配置")
            return
        }
        if (targets.length() == 0) {
            appendForwardingTrace("$eventDetail-邮件方式跳过：没有配置邮箱收件人")
            return
        }
        for (index in 0 until targets.length()) {
            val target = targets.optJSONObject(index) ?: continue
            val email = target.optString("value")
            if (email.isBlank()) {
                appendForwardingTrace("$eventDetail-邮件目标 ${index + 1} 跳过：邮箱为空")
                continue
            }

            appendForwardingTrace("$eventDetail-邮件目标 ${index + 1} 提交发送：to=$email")
            val sent = runCatching {
                val receivedAt = currentLocalTimeLabel()
                sendSmtpMail(
                    context = context,
                    smtp = smtp,
                    to = email,
                    subject = subject,
                    htmlBody = formattedEmailBody(
                        type = notificationType,
                        from = from,
                        to = to,
                        content = content,
                        time = receivedAt,
                    ),
                )
            }.getOrDefault(false)
            if (sent) {
                appendForwardingTrace("$eventDetail-邮件目标 ${index + 1} 发送成功：to=$email")
                appendEvent(context, "sms_forwarded", "已发送${notificationType}邮件到 $email")
            } else {
                appendForwardingTrace("$eventDetail-邮件目标 ${index + 1} 发送失败：to=$email")
                appendDebugEvent(context, "${eventDetail}失败：$email")
            }
        }
    }

    private fun forwardingDetectionSummary(config: JSONObject): String {
        val forwarding = config.optJSONObject("forwarding") ?: JSONObject()
        val smsTargets = forwarding.optJSONArray("smsTargets") ?: JSONArray()
        val emailTargets = forwarding.optJSONArray("emailTargets") ?: JSONArray()
        val httpTargets = forwarding.optJSONArray("httpTargets") ?: JSONArray()
        return "检测配置：smsTargets=${smsTargets.length()} emailTargets=${emailTargets.length()} httpTargets=${httpTargets.length()} smtpConfigured=${forwarding.optJSONObject("smtp") != null}"
    }

    private fun configSummary(config: JSONObject): String {
        val forwarding = config.optJSONObject("forwarding") ?: JSONObject()
        val commands = config.optJSONObject("commands") ?: JSONObject()
        val smsTargets = forwarding.optJSONArray("smsTargets")?.length() ?: 0
        val emailTargets = forwarding.optJSONArray("emailTargets")?.length() ?: 0
        val httpTargets = forwarding.optJSONArray("httpTargets")?.length() ?: 0
        val trustedNumbers = commands.optJSONArray("trustedNumbers")?.length() ?: 0
        val hasSmtp = forwarding.optJSONObject("smtp") != null
        val selectedSim = forwarding.optString("selectedSmsSim").ifBlank { "默认发送卡" }
        return "当前配置：手机号目标 $smsTargets，邮箱目标 $emailTargets，HTTP 目标 $httpTargets，SMTP ${if (hasSmtp) "已配置" else "未配置"}，白名单 $trustedNumbers，发送卡 $selectedSim"
    }

    private fun formattedEmailBody(
        type: String,
        from: String,
        to: String,
        content: String,
        time: String,
    ): String {
        val rows = listOf(
            "Type" to type,
            "From" to from,
            "To" to to,
            "Time" to time,
        ).joinToString(separator = "") { (label, value) ->
            """
            <tr>
              <td style="width:88px;padding:10px 12px;color:#64748b;font-weight:700;border-bottom:1px solid #e2e8f0;">${htmlEscape(label)}</td>
              <td style="padding:10px 12px;color:#0f172a;border-bottom:1px solid #e2e8f0;">${htmlEscape(value)}</td>
            </tr>
            """.trimIndent()
        }
        return """
            <!doctype html>
            <html>
              <body style="margin:0;padding:24px;background:#f8fafc;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Arial,sans-serif;color:#0f172a;">
                <div style="max-width:640px;margin:0 auto;background:#ffffff;border:1px solid #e2e8f0;border-radius:10px;overflow:hidden;">
                  <div style="padding:16px 18px;background:#0f766e;color:#ffffff;">
                    <div style="font-size:18px;font-weight:800;">Nami ${htmlEscape(type)}</div>
                  </div>
                  <table role="presentation" cellspacing="0" cellpadding="0" style="width:100%;border-collapse:collapse;font-size:14px;">
                    $rows
                  </table>
                  ${contentBlock(content)}
                </div>
              </body>
            </html>
        """.trimIndent()
    }

    private fun contentBlock(content: String): String {
        if (content.isBlank()) {
            return ""
        }
        return """
                  <div style="padding:16px 18px;">
                    <div style="margin-bottom:8px;color:#64748b;font-size:13px;font-weight:800;text-transform:uppercase;letter-spacing:.04em;">Content</div>
                    <div style="white-space:pre-wrap;line-height:1.6;font-size:15px;color:#0f172a;background:#f8fafc;border:1px solid #e2e8f0;border-radius:8px;padding:14px;">${htmlEscape(content)}</div>
                  </div>
        """.trimIndent()
    }

    private fun htmlEscape(value: String): String {
        return value
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
            .replace("\"", "&quot;")
            .replace("'", "&#39;")
    }

    private fun sendSmtpMail(
        context: Context,
        smtp: JSONObject,
        to: String,
        subject: String,
        htmlBody: String,
    ): Boolean {
        val host = smtp.optString("host")
        val port = smtp.optString("port").toIntOrNull() ?: 465
        val fromEmail = smtp.optString("fromEmail")
        val username = smtp.optString("username")
        val password = smtp.optString("password")
        if (host.isBlank() || fromEmail.isBlank() || username.isBlank() || password.isBlank()) {
            appendDebugEvent(
                context,
                "邮件转发失败：SMTP 配置不完整，host=${host.ifBlank { "未配置" }}，port=$port，from=${fromEmail.ifBlank { "未配置" }}，username=${username.ifBlank { "未配置" }}",
            )
            return false
        }

        val sslSocketFactory = SSLSocketFactory.getDefault() as SSLSocketFactory
        var socket: Socket? = null
        var smtpReader: BufferedReader? = null
        var smtpWriter: OutputStreamWriter? = null
        var lastSmtpResponse: String? = null
        appendDebugEvent(context, "SMTP 开始连接：host=$host，port=$port，to=$to，from=$fromEmail")

        fun readResponse(): Int {
            var code = -1
            while (true) {
                val line = smtpReader?.readLine() ?: return code
                lastSmtpResponse = line
                code = line.take(3).toIntOrNull() ?: code
                if (line.length < 4 || line[3] != '-') {
                    return code
                }
            }
        }

        fun command(label: String, value: String, expected: Set<Int>): Boolean {
            smtpWriter?.write("$value\r\n")
            smtpWriter?.flush()
            val code = readResponse()
            val ok = code in expected
            appendDebugEvent(
                context,
                if (ok) {
                    "SMTP $label 成功：响应码 $code"
                } else {
                    "SMTP $label 失败：响应码 $code，期望 $expected，响应 ${lastSmtpResponse.orEmpty()}"
                },
            )
            return ok
        }

        try {
            socket = if (port == 465) {
                sslSocketFactory.createSocket(host, port) as Socket
            } else {
                Socket(host, port)
            }
            socket.soTimeout = 15000
            smtpReader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.UTF_8))
            smtpWriter = OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8)

            val greetingCode = readResponse()
            if (greetingCode != 220) {
                appendDebugEvent(context, "SMTP 连接问候失败：响应码 $greetingCode，响应 ${lastSmtpResponse.orEmpty()}")
                return false
            }
            appendDebugEvent(context, "SMTP 连接成功：响应码 $greetingCode")
            if (!command("EHLO", "EHLO doppel.local", setOf(250))) {
                return false
            }
            if (port != 465) {
                if (!command("STARTTLS", "STARTTLS", setOf(220))) {
                    return false
                }
                socket = sslSocketFactory.createSocket(socket, host, port, true) as Socket
                smtpReader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.UTF_8))
                smtpWriter = OutputStreamWriter(socket.getOutputStream(), Charsets.UTF_8)
                appendDebugEvent(context, "SMTP STARTTLS 已升级为 TLS")
                if (!command("EHLO-TLS", "EHLO doppel.local", setOf(250))) {
                    return false
                }
            }

            val auth = Base64.encodeToString(
                "\u0000$username\u0000$password".toByteArray(Charsets.UTF_8),
                Base64.NO_WRAP,
            )
            if (!command("AUTH PLAIN", "AUTH PLAIN $auth", setOf(235))) {
                return false
            }
            if (!command("MAIL FROM", "MAIL FROM:<$fromEmail>", setOf(250))) {
                return false
            }
            if (!command("RCPT TO", "RCPT TO:<$to>", setOf(250, 251))) {
                return false
            }
            if (!command("DATA", "DATA", setOf(354))) {
                return false
            }
            val message = buildString {
                append("From: <$fromEmail>\r\n")
                append("To: <$to>\r\n")
                append("Subject: $subject\r\n")
                append("MIME-Version: 1.0\r\n")
                append("Content-Type: text/html; charset=UTF-8\r\n")
                append("\r\n")
                append(htmlBody.replace("\r\n.", "\r\n.."))
                append("\r\n.\r\n")
            }
            smtpWriter?.write(message)
            smtpWriter?.flush()
            val dataCode = readResponse()
            if (dataCode !in setOf(250)) {
                appendDebugEvent(context, "SMTP 邮件提交失败：响应码 $dataCode，响应 ${lastSmtpResponse.orEmpty()}")
                return false
            }
            appendDebugEvent(context, "SMTP 邮件提交成功：响应码 $dataCode")
            command("QUIT", "QUIT", setOf(221))
            return true
        } catch (error: Throwable) {
            appendDebugEvent(
                context,
                "SMTP 转发异常：${error.javaClass.simpleName}，${error.message.orEmpty()}",
            )
            return false
        } finally {
            smtpReader = null
            smtpWriter = null
            lastSmtpResponse = null
            runCatching { socket?.close() }
        }
    }

    private fun smsManager(context: Context, config: JSONObject, selectedSim: String = ""): SmsManager {
        val label = selectedSim.ifBlank {
            config.optJSONObject("forwarding")?.optString("selectedSmsSim").orEmpty()
        }
        val subscriptionId = subscriptionIdForLabel(context, label)
        return if (subscriptionId != null) {
            appendDebugEvent(context, "使用指定短信发送卡：$label，subscriptionId=$subscriptionId")
            SmsManager.getSmsManagerForSubscriptionId(subscriptionId)
        } else {
            appendDebugEvent(context, "未匹配到指定短信发送卡：${label.ifBlank { "未配置" }}，使用系统默认短信发送卡")
            SmsManager.getDefault()
        }
    }

    private fun applyCallSimExtras(context: Context, intent: Intent, selectedSim: String) {
        val info = subscriptionForLabel(context, selectedSim) ?: return
        val slotIndex = info.simSlotIndex
        val subscriptionId = info.subscriptionId
        intent.putExtra("com.android.phone.extra.slot", slotIndex)
        intent.putExtra("slot", slotIndex)
        intent.putExtra("simSlot", slotIndex)
        intent.putExtra("subscription", subscriptionId)
        intent.putExtra("subscription_id", subscriptionId)
        intent.putExtra("android.telephony.extra.SUBSCRIPTION_INDEX", subscriptionId)
        appendDebugEvent(
            context,
            "远程拨号使用指定 SIM：$selectedSim，slot=$slotIndex subscriptionId=$subscriptionId",
        )
    }

    private fun placeCallWithTelecomManager(context: Context, phone: String, selectedSim: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return false
        }
        val telecomManager = context.getSystemService(TelecomManager::class.java) ?: return false
        val extras = Bundle()
        phoneAccountHandleForLabel(context, selectedSim)?.let { handle ->
            extras.putParcelable(TelecomManager.EXTRA_PHONE_ACCOUNT_HANDLE, handle)
        }
        telecomManager.placeCall(Uri.parse("tel:$phone"), extras)
        appendDebugEvent(context, "远程拨号已通过 TelecomManager 提交")
        return true
    }

    private fun phoneAccountHandleForLabel(context: Context, selectedSim: String): PhoneAccountHandle? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            return null
        }
        val info = subscriptionForLabel(context, selectedSim) ?: return null
        val subscriptionId = info.subscriptionId.toString()
        val slotIndex = info.simSlotIndex.toString()
        return runCatching {
            val telecomManager = context.getSystemService(TelecomManager::class.java) ?: return@runCatching null
            telecomManager.callCapablePhoneAccounts.firstOrNull { handle ->
                handle.id == subscriptionId ||
                    handle.id.contains(subscriptionId) ||
                    handle.id.contains(slotIndex)
            }
        }.getOrNull()
    }

    private fun startCallActivity(context: Context, phone: String, selectedSim: String) {
        val intent = Intent(Intent.ACTION_CALL, Uri.parse("tel:$phone"))
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        applyCallSimExtras(context, intent, selectedSim)
        context.startActivity(intent)
    }

    private fun localRecipientLabel(
        context: Context,
        subscriptionId: Int,
        fallbackToFirstSubscription: Boolean = true,
        unknownLabel: String = "未读取本机号码",
    ): String {
        if (context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) {
            return "未授权读取本机号码"
        }
        val manager = context.getSystemService(SubscriptionManager::class.java)
        val subscriptions = runCatching {
            manager.activeSubscriptionInfoList.orEmpty()
        }.getOrDefault(emptyList())
        if (subscriptionId < 0) {
            if (!fallbackToFirstSubscription) {
                return unknownLabel
            }
            return subscriptions
                .map(::subscriptionLabel)
                .firstOrNull { it.isNotBlank() && it != "未读取号码" }
                ?: unknownLabel
        }
        val info = runCatching { subscriptions.firstOrNull { it.subscriptionId == subscriptionId } }
            .getOrNull()
            ?: return "$unknownLabel subscriptionId=$subscriptionId"

        return subscriptionLabel(info).ifBlank { "$unknownLabel subscriptionId=$subscriptionId" }
    }

    private fun subscriptionLabel(info: android.telephony.SubscriptionInfo): String {
        val number = runCatching { info.number.orEmpty() }.getOrDefault("")
        if (number.isNotBlank()) {
            return number
        }
        val displayName = info.displayName?.toString().orEmpty()
        val carrierName = info.carrierName?.toString().orEmpty()
        return listOf(displayName, carrierName)
            .filter { it.isNotBlank() }
            .distinct()
            .joinToString(" · ")
            .ifBlank { "未读取号码" }
    }

    private fun latestIncomingCallNumber(context: Context): String {
        if (context.checkSelfPermission(Manifest.permission.READ_CALL_LOG) != PackageManager.PERMISSION_GRANTED) {
            appendDebugEvent(context, "来电号码为空，跳过通话记录兜底：缺少 READ_CALL_LOG 权限")
            return ""
        }
        val uri = CallLog.Calls.CONTENT_URI
        val projection = arrayOf(CallLog.Calls.NUMBER, CallLog.Calls.TYPE, CallLog.Calls.DATE)
        val since = (System.currentTimeMillis() - 30000L).toString()
        val cursor = runCatching {
            context.contentResolver.query(
                uri,
                projection,
                "${CallLog.Calls.TYPE} = ? AND ${CallLog.Calls.DATE} >= ?",
                arrayOf(CallLog.Calls.INCOMING_TYPE.toString(), since),
                "${CallLog.Calls.DATE} DESC",
            )
        }.getOrNull()
        return cursor?.use {
            if (it.moveToFirst()) {
                it.getString(it.getColumnIndexOrThrow(CallLog.Calls.NUMBER)).orEmpty()
            } else {
                ""
            }
        }.orEmpty().also {
            appendDebugEvent(
                context,
                if (it.isBlank()) {
                    "来电号码为空，通话记录兜底未读取到最近呼入号码"
                } else {
                    "来电号码为空，已从通话记录兜底读取号码"
                },
            )
        }
    }

    private fun latestInboxSmsDate(context: Context): Long? {
        val projection = arrayOf(Telephony.Sms.DATE)
        val cursor = runCatching {
            context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                projection,
                "${Telephony.Sms.TYPE} = ?",
                arrayOf(Telephony.Sms.MESSAGE_TYPE_INBOX.toString()),
                "${Telephony.Sms.DATE} DESC",
            )
        }.getOrNull() ?: return null
        return cursor.use {
            if (it.moveToFirst()) {
                it.getLong(it.getColumnIndexOrThrow(Telephony.Sms.DATE))
            } else {
                null
            }
        }
    }

    private fun recentInboxSmsAfter(context: Context, since: Long): List<BackfillSms> {
        val projection = arrayOf(
            Telephony.Sms._ID,
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE,
            Telephony.Sms.TYPE,
        )
        val cursor = runCatching {
            context.contentResolver.query(
                Telephony.Sms.CONTENT_URI,
                projection,
                "${Telephony.Sms.TYPE} = ? AND ${Telephony.Sms.DATE} > ?",
                arrayOf(Telephony.Sms.MESSAGE_TYPE_INBOX.toString(), since.toString()),
                "${Telephony.Sms.DATE} ASC",
            )
        }.getOrNull() ?: return emptyList()

        return cursor.use { rows ->
            buildList {
                while (rows.moveToNext() && size < MAX_BACKFILL_SMS_COUNT) {
                    add(rows.toBackfillSms())
                }
            }
        }
    }

    private fun Cursor.toBackfillSms(): BackfillSms {
        return BackfillSms(
            id = getLong(getColumnIndexOrThrow(Telephony.Sms._ID)),
            sender = getString(getColumnIndexOrThrow(Telephony.Sms.ADDRESS)).orEmpty(),
            body = getString(getColumnIndexOrThrow(Telephony.Sms.BODY)).orEmpty(),
            date = getLong(getColumnIndexOrThrow(Telephony.Sms.DATE)),
        )
    }

    private fun subscriptionIdForLabel(context: Context, label: String): Int? {
        return subscriptionForLabel(context, label)?.subscriptionId
    }

    private fun subscriptionForLabel(context: Context, label: String): android.telephony.SubscriptionInfo? {
        if (label.isBlank() || context.checkSelfPermission(Manifest.permission.READ_PHONE_STATE) != PackageManager.PERMISSION_GRANTED) {
            return null
        }
        val manager = context.getSystemService(SubscriptionManager::class.java)
        val subscriptions = runCatching { manager.activeSubscriptionInfoList.orEmpty() }.getOrDefault(emptyList())
        return subscriptions.firstOrNull { matchesSubscriptionLabel(it, label) }
    }

    private fun matchesSubscriptionLabel(info: android.telephony.SubscriptionInfo, label: String): Boolean {
        val displayName = info.displayName?.toString().orEmpty().ifBlank { "未命名卡" }
        val carrierName = info.carrierName?.toString().orEmpty()
        val number = runCatching { info.number.orEmpty() }.getOrDefault("")
        val possibleLabels = listOf(
            "$displayName · $number",
            "$displayName · 未读取号码",
            "卡槽 ${info.simSlotIndex + 1} · $carrierName · $displayName · $number",
            "卡槽 ${info.simSlotIndex + 1} · $carrierName · $displayName · 未读取号码",
        )
        return possibleLabels.any { it == label } ||
            label.startsWith("$displayName ·") ||
            label.startsWith("卡槽 ${info.simSlotIndex + 1} ·")
    }

    private fun parseCommand(body: String): SmsCommand? {
        val trimmed = body.trim()
        val parts = trimmed.split(Regex("\\s+"), limit = 4)
        if (parts.size < 3 || !parts[0].equals("DOPPEL", ignoreCase = true)) {
            return null
        }
        return when (parts[1].uppercase()) {
            "CALL" -> SmsCommand.Call(parts[2])
            "SMS" -> if (parts.size >= 4) SmsCommand.SendSms(parts[2], parts[3]) else null
            else -> null
        }
    }

    private fun isTrustedSender(config: JSONObject, sender: String): Boolean {
        return trustedNumber(config, sender) != null
    }

    private fun trustedNumber(config: JSONObject, sender: String): JSONObject? {
        val trusted = config.optJSONObject("commands")?.optJSONArray("trustedNumbers") ?: JSONArray()
        val normalizedSender = sender.filter(Char::isDigit)
        for (index in 0 until trusted.length()) {
            val item = trusted.optJSONObject(index) ?: continue
            val number = item.optString("number").filter(Char::isDigit)
            if (number.isNotBlank() && normalizedSender.endsWith(number.takeLast(11))) {
                return item
            }
        }
        return null
    }

    private fun readConfig(context: Context): JSONObject {
        val prefs = pipelinePrefs(context)
        return runCatching {
            JSONObject(prefs.getString(KEY_CONFIG, "{}") ?: "{}")
        }.getOrDefault(JSONObject())
    }

    private fun appendEvent(context: Context, type: String, detail: String, extras: JSONObject? = null) {
        if (shouldLogEventToLogcat(type)) {
            Log.i(PIPELINE_TAG, detail)
        }
        val prefs = pipelinePrefs(context)
        val events = runCatching {
            JSONArray(prefs.getString(KEY_EVENTS, "[]") ?: "[]")
        }.getOrDefault(JSONArray())
        val event = JSONObject()
            .put("type", type)
            .put("detail", detail)
            .put("timestamp", Instant.now().toString())
        if (extras != null) {
            extras.keys().forEach { key ->
                event.put(key, extras.opt(key))
            }
        }
        events.put(event)
        val trimmed = JSONArray()
        val start = maxOf(0, events.length() - 500)
        for (index in start until events.length()) {
            trimmed.put(events.get(index))
        }
        prefs.edit().putString(KEY_EVENTS, trimmed.toString()).apply()
        context.sendBroadcast(
            Intent(ACTION_DOPPEL_SNAPSHOT_CHANGED).setPackage(context.packageName),
        )
    }

    private fun pipelinePrefs(context: Context): android.content.SharedPreferences {
        if (isUserUnlocked(context)) {
            return context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        }
        val directBootContext = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            context.createDeviceProtectedStorageContext()
        } else {
            context
        }
        return directBootContext.getSharedPreferences(DIRECT_BOOT_PREFS_NAME, Context.MODE_PRIVATE)
    }

    private fun shouldLogEventToLogcat(type: String): Boolean {
        return when (type) {
            "sms_pipeline_debug",
            "sms_received",
            "sms_forwarded" -> false
            else -> true
        }
    }
}

private data class BackfillSms(
    val id: Long,
    val sender: String,
    val body: String,
    val date: Long,
)

internal sealed class SmsCommand {
    data class Call(val number: String) : SmsCommand()
    data class SendSms(val number: String, val message: String) : SmsCommand()

    val label: String
        get() = when (this) {
            is Call -> "CALL"
            is SendSms -> "SMS"
        }
}
