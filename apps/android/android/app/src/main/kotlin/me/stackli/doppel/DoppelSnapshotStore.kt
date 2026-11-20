package me.stackli.doppel

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.database.Cursor
import android.os.Build
import android.provider.Telephony
import android.telephony.SubscriptionInfo
import android.telephony.SubscriptionManager
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import me.stackli.doppel.agent.AgentRuntime

internal object DoppelSnapshotStore {
    private const val PREFS_NAME = "doppel"
    private const val KEY_EVENTS = "events_json"
    private const val SMS_HISTORY_WINDOW_MILLIS = 30L * 24L * 60L * 60L * 1000L
    private const val DIAGNOSTIC_GRACE_PERIOD_MILLIS = 2L * 60L * 1000L
    private const val RECENT_SMS_DIAGNOSTIC_WINDOW_MILLIS = 10L * 60L * 1000L

    fun buildSnapshotJson(context: Context): JSONObject {
        val config = RemoteControlStore.readConfigJson(context)
        return JSONObject()
            .put("permissions", permissionsJson(context))
            .put("simCards", JSONArray(readSimCards(context)))
            .put("events", readEvents(context, config))
            .put("remoteControlStatus", RemoteControlStore.remoteControlStatusJson(context))
            .put("config", config)
    }

    fun buildSnapshotMap(context: Context): Map<String, Any?> {
        return buildSnapshotJson(context).toMapValue()
    }

    private fun permissionsJson(context: Context): JSONObject {
        return JSONObject()
            .put("receiveSms", hasPermission(context, Manifest.permission.RECEIVE_SMS))
            .put("readSms", hasPermission(context, Manifest.permission.READ_SMS))
            .put("readCallLog", hasPermission(context, Manifest.permission.READ_CALL_LOG))
            .put("sendSms", hasPermission(context, Manifest.permission.SEND_SMS))
            .put("callPhone", hasPermission(context, Manifest.permission.CALL_PHONE))
            .put("readPhoneState", hasPermission(context, Manifest.permission.READ_PHONE_STATE))
            .put("readPhoneNumbers", hasPermission(context, Manifest.permission.READ_PHONE_NUMBERS))
            .put(
                "sms",
                hasPermission(context, Manifest.permission.RECEIVE_SMS) &&
                    hasPermission(context, Manifest.permission.SEND_SMS),
            )
            .put(
                "phone",
                hasPermission(context, Manifest.permission.READ_PHONE_STATE) &&
                    hasPermission(context, Manifest.permission.CALL_PHONE),
            )
            .put("phoneNumbers", hasPermission(context, Manifest.permission.READ_PHONE_NUMBERS))
    }

    private fun hasPermission(context: Context, permission: String): Boolean {
        return context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    }

    private fun readSimCards(context: Context): List<JSONObject> {
        if (!hasPermission(context, Manifest.permission.READ_PHONE_STATE)) {
            return emptyList()
        }

        val manager = context.getSystemService(SubscriptionManager::class.java)
        val activeSubscriptions = runCatching {
            manager.activeSubscriptionInfoList.orEmpty()
        }.getOrDefault(emptyList())

        return activeSubscriptions.map { it.toJson(context) }
    }

    private fun SubscriptionInfo.toJson(context: Context): JSONObject {
        val rawNumber = if (
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            hasPermission(context, Manifest.permission.READ_PHONE_NUMBERS)
        ) {
            runCatching { number.orEmpty() }.getOrDefault("")
        } else {
            ""
        }

        return JSONObject()
            .put("subscriptionId", subscriptionId)
            .put("slotIndex", simSlotIndex)
            .put("displayName", displayName?.toString().orEmpty())
            .put("carrierName", carrierName?.toString().orEmpty())
            .put("number", rawNumber.ifBlank { "未读取号码" })
    }

    private fun readEvents(context: Context, config: JSONObject): JSONArray {
        val agentEvents = AgentRuntime.snapshot(context).optJSONArray("events") ?: JSONArray()
        val storedEvents = readStoredEvents(context) + List(agentEvents.length()) { agentEvents.getJSONObject(it) }
        val smsHistoryEvents = readRecentSmsHistory(context, config)
        return JSONArray(mergeEvents(storedEvents, smsHistoryEvents))
    }

    private fun readStoredEvents(context: Context): List<JSONObject> {
        val raw = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
            .getString(KEY_EVENTS, "[]") ?: "[]"
        val array = runCatching { JSONArray(raw) }.getOrDefault(JSONArray())
        return buildList {
            for (index in 0 until array.length()) {
                val item = array.optJSONObject(index) ?: continue
                add(item)
            }
        }
    }

    private fun readRecentSmsHistory(context: Context, config: JSONObject): List<JSONObject> {
        if (!hasPermission(context, Manifest.permission.READ_SMS)) {
            return emptyList()
        }

        val since = System.currentTimeMillis() - SMS_HISTORY_WINDOW_MILLIS
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
                "${Telephony.Sms.DATE} >= ?",
                arrayOf(since.toString()),
                "${Telephony.Sms.DATE} DESC",
            )
        }.getOrNull() ?: return emptyList()

        return cursor.use { rows ->
            buildList {
                while (rows.moveToNext()) {
                    add(rows.toSmsEventJson(config))
                }
            }
        }
    }

    private fun Cursor.toSmsEventJson(config: JSONObject): JSONObject {
        val id = getLong(getColumnIndexOrThrow(Telephony.Sms._ID))
        val address = getString(getColumnIndexOrThrow(Telephony.Sms.ADDRESS)).orEmpty()
        val body = getString(getColumnIndexOrThrow(Telephony.Sms.BODY)).orEmpty()
        val date = getLong(getColumnIndexOrThrow(Telephony.Sms.DATE))
        val smsType = getInt(getColumnIndexOrThrow(Telephony.Sms.TYPE))
        val direction = when (smsType) {
            Telephony.Sms.MESSAGE_TYPE_SENT -> "发出"
            Telephony.Sms.MESSAGE_TYPE_OUTBOX -> "待发"
            Telephony.Sms.MESSAGE_TYPE_FAILED -> "发送失败"
            Telephony.Sms.MESSAGE_TYPE_QUEUED -> "排队发送"
            else -> "收到"
        }
        val eventType = if (smsType == Telephony.Sms.MESSAGE_TYPE_INBOX) {
            "sms_received"
        } else {
            "sms_history"
        }
        return JSONObject()
            .put("id", "system_sms_$id")
            .put("source", "system_sms")
            .put("type", eventType)
            .put("detail", "$direction $address：$body")
            .put("timestamp", Instant.ofEpochMilli(date).toString())
            .put("from", address)
            .put("to", localSmsRecipientLabel(config))
            .put("content", body)
    }

    private fun localSmsRecipientLabel(config: JSONObject): String {
        val selected = config.optJSONObject("forwarding")
            ?.optString("selectedSmsSim")
            .orEmpty()
        return selected.substringAfterLast(" · ", selected).ifBlank { "未读取本机号码" }
    }

    private fun mergeEvents(
        storedEvents: List<JSONObject>,
        smsHistoryEvents: List<JSONObject>,
    ): List<JSONObject> {
        val byId = linkedMapOf<String, JSONObject>()
        val diagnosticEvents = recentHistoryDiagnostics(storedEvents, smsHistoryEvents)
        (storedEvents + smsHistoryEvents + diagnosticEvents).forEachIndexed { index, event ->
            val id = event.optString("id").ifBlank {
                "${event.optString("type")}:${event.optString("timestamp")}:${event.optString("detail")}:$index"
            }
            byId[id] = event
        }
        return byId.values.sortedByDescending(::eventTimestampMillis)
    }

    private fun recentHistoryDiagnostics(
        storedEvents: List<JSONObject>,
        smsHistoryEvents: List<JSONObject>,
    ): List<JSONObject> {
        val now = System.currentTimeMillis()
        val hasRecentPipelineDebug = storedEvents.any { event ->
            event.optString("type") == "sms_pipeline_debug" &&
                eventTimestampMillis(event) >= now - RECENT_SMS_DIAGNOSTIC_WINDOW_MILLIS
        }
        if (hasRecentPipelineDebug) {
            return emptyList()
        }

        return smsHistoryEvents
            .filter { event ->
                val eventTime = eventTimestampMillis(event)
                val age = now - eventTime
                event.optString("type") == "sms_received" &&
                    age in DIAGNOSTIC_GRACE_PERIOD_MILLIS..RECENT_SMS_DIAGNOSTIC_WINDOW_MILLIS
            }
            .take(1)
            .map { event ->
                JSONObject()
                    .put("id", "diagnostic_${event.optString("id")}")
                    .put("type", "sms_pipeline_debug")
                    .put("detail", "历史短信导入发现新短信，但没有实时接收/转发日志；可能是系统短信广播没有送达 Nami")
                    .put("timestamp", event.optString("timestamp"))
            }
    }

    private fun eventTimestampMillis(event: JSONObject): Long {
        return runCatching {
            Instant.parse(event.optString("timestamp")).toEpochMilli()
        }.getOrDefault(0L)
    }
}
