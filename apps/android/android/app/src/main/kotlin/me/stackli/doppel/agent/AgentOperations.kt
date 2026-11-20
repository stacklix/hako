package me.stackli.doppel.agent

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import android.net.Uri
import android.telecom.TelecomManager
import android.telephony.SmsManager
import android.telephony.SubscriptionManager
import org.json.JSONObject
import java.security.MessageDigest
import java.time.Instant
import java.util.UUID

internal class AgentOperationStore(context: Context) : SQLiteOpenHelper(context, "hako-operations.db", null, 1), java.io.Closeable {
    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE operations (id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, kind TEXT NOT NULL, status TEXT NOT NULL, parts INTEGER NOT NULL DEFAULT 0, message TEXT NOT NULL, updated_at TEXT NOT NULL)")
        db.execSQL("CREATE TABLE receipts (operation_id TEXT NOT NULL, part INTEGER NOT NULL, successful INTEGER NOT NULL, PRIMARY KEY(operation_id, part))")
    }
    override fun onUpgrade(db: SQLiteDatabase, old: Int, new: Int) = Unit

    @Synchronized
    fun begin(id: String, fingerprint: String, kind: String): JSONObject? {
        val db = writableDatabase
        db.beginTransaction()
        try {
            val existing = get(id)
            if (existing != null) {
                val stored = db.rawQuery("SELECT fingerprint FROM operations WHERE id=?", arrayOf(id)).use { it.moveToFirst(); it.getString(0) }
                if (stored != fingerprint) throw AgentError("request_conflict", "操作 ID 已用于其他参数")
                db.setTransactionSuccessful()
                return existing
            }
            db.execSQL("INSERT INTO operations(id,fingerprint,kind,status,message,updated_at) VALUES(?,?,?,'submitting',?,?)",
                arrayOf(id, fingerprint, kind, "已记录执行意图；若结果未确认，请勿换用新 ID 重试", Instant.now().toString()))
            db.setTransactionSuccessful()
            return null
        } finally { db.endTransaction() }
    }

    fun get(id: String): JSONObject? = readableDatabase.rawQuery(
        "SELECT id,kind,status,message,updated_at FROM operations WHERE id=?", arrayOf(id)
    ).use { cursor ->
        if (!cursor.moveToFirst()) null else JSONObject().put("requestId", cursor.getString(0))
            .put("kind", cursor.getString(1)).put("status", cursor.getString(2))
            .put("message", cursor.getString(3)).put("updatedAt", cursor.getString(4))
    }

    fun setParts(id: String, count: Int) {
        writableDatabase.execSQL("UPDATE operations SET parts=? WHERE id=?", arrayOf<Any>(count, id))
    }

    fun update(id: String, status: String, message: String, onlySubmitting: Boolean = false) {
        val values = ContentValues().apply {
            put("status", status); put("message", message); put("updated_at", Instant.now().toString())
        }
        writableDatabase.update("operations", values,
            if (onlySubmitting) "id=? AND status='submitting'" else "id=?", arrayOf(id))
    }

    fun receipt(id: String, part: Int, successful: Boolean) {
        val db = writableDatabase
        db.beginTransaction()
        try {
            val count = db.rawQuery("SELECT parts FROM operations WHERE id=? AND kind='sms'", arrayOf(id)).use {
                if (it.moveToFirst()) it.getInt(0) else 0
            }
            if (part !in 0 until count) return
            db.execSQL("INSERT OR IGNORE INTO receipts(operation_id,part,successful) VALUES(?,?,?)", arrayOf<Any>(id, part, if (successful) 1 else 0))
            db.rawQuery("SELECT COUNT(*),MIN(successful) FROM receipts WHERE operation_id=?", arrayOf(id)).use {
                it.moveToFirst()
                if (it.getInt(1) == 0) update(id, "failed", "至少一个短信分段发送失败，请在手机上检查")
                else if (it.getInt(0) == count) update(id, "sent", "全部短信分段发送成功；未确认对方送达")
            }
            db.setTransactionSuccessful()
        } finally { db.endTransaction() }
    }
}

internal class AgentActions(private val context: Context) {
    private fun permission(name: String) {
        if (context.checkSelfPermission(name) != PackageManager.PERMISSION_GRANTED) {
            throw AgentError("permission_denied", "请在手机上授予对应权限")
        }
    }
    private fun requestId(params: JSONObject): String {
        val id = AgentProtocol.string(params, "requestId", 36)
        if (runCatching { UUID.fromString(id).toString() }.getOrNull() != id) AgentProtocol.invalid("requestId 需要为小写标准 UUID")
        return id
    }
    private fun number(params: JSONObject): String {
        val value = AgentProtocol.string(params, "number", 32).trim()
        if (!value.matches(Regex("\\+?[0-9]{3,20}"))) AgentProtocol.invalid("电话号码需要为 3 到 20 位数字，可带国际区号 +")
        return value
    }
    private fun fingerprint(vararg values: String) = MessageDigest.getInstance("SHA-256")
        .digest(org.json.JSONArray(values.toList()).toString().toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }

    fun lookup(params: JSONObject): JSONObject {
        AgentProtocol.fields(params, setOf("requestId"))
        return AgentOperationStore(context).use { it.get(requestId(params)) }
            ?: throw AgentError("operation_not_found", "未找到该操作")
    }

    @Synchronized
    fun sendSms(params: JSONObject): JSONObject {
        AgentProtocol.fields(params, setOf("requestId", "number", "text", "subscriptionId"))
        val id = requestId(params)
        val phone = number(params)
        val text = AgentProtocol.string(params, "text", 4000)
        val subscription = params.opt("subscriptionId")
        if (subscription != null && (subscription !is Int || subscription < 0)) AgentProtocol.invalid("subscriptionId 需要为非负整数")
        AgentOperationStore(context).use { store ->
            // Existing receipts remain queryable after permissions or local switches change.
            val hash = fingerprint("sms", phone, text, (subscription ?: "default").toString())
            store.get(id)?.let { return store.begin(id, hash, "sms")!! }
            if (!AgentSettingsStore(context).read().allowSms) throw AgentError("action_disabled", "请先在手机上开启远程发送短信")
            permission(Manifest.permission.SEND_SMS)
            val subId = subscription as? Int ?: SubscriptionManager.getDefaultSmsSubscriptionId()
            if (!SubscriptionManager.isValidSubscriptionId(subId)) AgentProtocol.invalid("请选择可用的短信 SIM 卡")
            store.begin(id, hash, "sms")?.let { return it }
            try {
                @Suppress("DEPRECATION")
                val manager = SmsManager.getSmsManagerForSubscriptionId(subId)
                val parts = manager.divideMessage(text)
                store.setParts(id, parts.size)
                val receipts = ArrayList(parts.indices.map { index ->
                    val intent = Intent(context, AgentSmsSentReceiver::class.java)
                        .setData(Uri.parse("hako-sms://receipt/$id/$index"))
                        .putExtra("requestId", id).putExtra("part", index)
                    PendingIntent.getBroadcast(context, 0, intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                })
                manager.sendMultipartTextMessage(phone, null, parts, receipts, null)
                store.update(id, "submitted", "短信发送请求已提交，等待系统发送回执", onlySubmitting = true)
            } catch (_: Exception) {
                store.update(id, "unknown", "发送调用未正常结束，实际发送情况待确认；不会自动重试", onlySubmitting = true)
            }
            return store.get(id)!!
        }
    }

    @Synchronized
    fun call(params: JSONObject): JSONObject {
        AgentProtocol.fields(params, setOf("requestId", "number"))
        val id = requestId(params)
        val phone = number(params)
        AgentOperationStore(context).use { store ->
            val hash = fingerprint("call", phone)
            store.get(id)?.let { return store.begin(id, hash, "call")!! }
            if (!AgentSettingsStore(context).read().allowCalls) throw AgentError("action_disabled", "请先在手机上开启远程拨号")
            permission(Manifest.permission.CALL_PHONE)
            store.begin(id, hash, "call")?.let { return it }
            try {
                requireNotNull(context.getSystemService(TelecomManager::class.java)).placeCall(Uri.fromParts("tel", phone, null), android.os.Bundle())
                store.update(id, "submitted", "拨号请求已提交；不代表电话已接通")
            } catch (_: Exception) {
                store.update(id, "unknown", "拨号调用未正常结束，实际呼叫情况待确认；不会自动重试")
            }
            return store.get(id)!!
        }
    }
}

class AgentSmsSentReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("requestId") ?: return
        val part = intent.getIntExtra("part", -1)
        AgentOperationStore(context).use { it.receipt(id, part, resultCode == Activity.RESULT_OK) }
    }
}
