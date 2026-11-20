package me.stackli.doppel.agent

import android.Manifest
import android.app.ActivityManager
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import android.os.SystemClock
import android.provider.CallLog
import android.provider.Telephony
import android.telephony.SubscriptionManager
import me.stackli.doppel.BuildConfig
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant

internal interface AgentCommands {
    fun invoke(method: String, version: Int, params: JSONObject): JSONObject
}

internal class AgentDispatcher(private val context: Context) : AgentCommands {
    private val actions = AgentActions(context)

    override fun invoke(method: String, version: Int, params: JSONObject): JSONObject {
        if (version != 1) throw AgentError("unsupported_version", "不支持此命令版本")
        if (method == "query.all") {
            AgentProtocol.fields(params, emptySet())
            // Only explicitly registered state providers participate. History is always queried separately.
            return AgentProtocol.aggregate { invoke(it, 1, JSONObject()) }
        }
        if (AgentProtocol.capabilities.none { it.name == method }) throw AgentError("unknown_method", "设备不支持此命令")
        return when (method) {
            AgentLanState.COMMAND -> { AgentProtocol.fields(params, emptySet()); AgentLanState.snapshot(context) }
            "query.device.status" -> { AgentProtocol.fields(params, emptySet()); status() }
            AgentStorage.COMMAND -> { AgentProtocol.fields(params, emptySet()); AgentStorage.snapshot(context) }
            AgentBattery.COMMAND -> { AgentProtocol.fields(params, emptySet()); AgentBattery.snapshot(context) }
            AgentWifi.COMMAND -> { AgentProtocol.fields(params, emptySet()); AgentWifi.snapshot(context) }
            AgentScreen.COMMAND -> { AgentProtocol.fields(params, emptySet()); AgentScreen.snapshot(context) }
            "query.telephony.sims" -> { AgentProtocol.fields(params, emptySet()); sims() }
            "query.sms.messages" -> history(params, true)
            "query.telephony.calls" -> history(params, false)
            "query.device.operation" -> actions.lookup(params)
            "action.sms.send" -> actions.sendSms(params)
            "action.telephony.call" -> actions.call(params)
            else -> throw AgentError("unknown_method", "设备不支持此命令")
        }
    }

    private fun status(): JSONObject {
        val memory = ActivityManager.MemoryInfo()
        requireNotNull(context.getSystemService(ActivityManager::class.java)).getMemoryInfo(memory)
        val connectivity = requireNotNull(context.getSystemService(ConnectivityManager::class.java))
        val network = connectivity.getNetworkCapabilities(connectivity.activeNetwork)
        val transport = when {
            network == null -> "offline"
            network.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
            network.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            network.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "ethernet"
            else -> "other"
        }
        val settings = AgentSettingsStore(context).read()
        return JSONObject().put("platform", "android").put("manufacturer", Build.MANUFACTURER)
            .put("model", Build.MODEL).put("androidVersion", Build.VERSION.RELEASE)
            .put("sdk", Build.VERSION.SDK_INT).put("appVersion", BuildConfig.VERSION_NAME)
            .put("minimumServerVersion", AgentProtocol.MINIMUM_SERVER)
            .put("uptimeMs", SystemClock.elapsedRealtime()).put("network", transport)
            .put("memoryTotalBytes", memory.totalMem).put("memoryAvailableBytes", memory.availMem)
            .put("permissions", JSONObject()
                .put("readSms", granted(Manifest.permission.READ_SMS)).put("sendSms", granted(Manifest.permission.SEND_SMS))
                .put("readCalls", granted(Manifest.permission.READ_CALL_LOG)).put("callPhone", granted(Manifest.permission.CALL_PHONE))
                .put("readPhoneState", granted(Manifest.permission.READ_PHONE_STATE)))
            .put("allowSms", settings.allowSms).put("allowCalls", settings.allowCalls)
            .put("sampledAt", Instant.now().toString())
    }

    private fun sims(): JSONObject {
        requirePermission(Manifest.permission.READ_PHONE_STATE)
        val manager = requireNotNull(context.getSystemService(SubscriptionManager::class.java))
        val sims = manager.activeSubscriptionInfoList.orEmpty().map { info ->
            JSONObject().put("subscriptionId", info.subscriptionId).put("slotIndex", info.simSlotIndex)
                .put("displayName", info.displayName?.toString().orEmpty())
                .put("carrierName", info.carrierName?.toString().orEmpty())
        }
        return JSONObject().put("items", JSONArray(sims)).put("sampledAt", Instant.now().toString())
    }

    private fun history(params: JSONObject, sms: Boolean): JSONObject {
        AgentProtocol.fields(params, setOf("limit", "cursor"))
        val limit = AgentProtocol.limit(params)
        val before = AgentProtocol.cursor(params)
        requirePermission(if (sms) Manifest.permission.READ_SMS else Manifest.permission.READ_CALL_LOG)
        val columns = if (sms) arrayOf("_id", "address", "body", "date", "type", "sub_id")
            else arrayOf("_id", "number", "date", "duration", "type")
        val uri = if (sms) Telephony.Sms.CONTENT_URI else CallLog.Calls.CONTENT_URI
        val items = JSONArray()
        var next: String? = null
        try {
            context.contentResolver.query(uri, columns, if (before == null) null else "_id < ?",
                before?.let { arrayOf(it.toString()) }, "_id DESC")?.use { cursor ->
                while (cursor.moveToNext()) {
                    if (Thread.currentThread().isInterrupted) throw InterruptedException()
                    if (items.length() == limit) {
                        next = items.getJSONObject(items.length() - 1).getString("id")
                        break
                    }
                    val item = JSONObject().put("id", cursor.getLong(0).toString())
                    if (sms) {
                        item.put("number", cursor.getString(1) ?: "").put("text", cursor.getString(2) ?: "")
                            .put("timestamp", cursor.getLong(3)).put("type", cursor.getInt(4))
                            .put("subscriptionId", cursor.getInt(5))
                    } else {
                        item.put("number", cursor.getString(1) ?: "").put("timestamp", cursor.getLong(2))
                            .put("durationSeconds", cursor.getLong(3)).put("type", cursor.getInt(4))
                    }
                    items.put(item)
                }
            } ?: throw AgentError("query_failed", "系统未返回查询结果")
        } catch (_: SecurityException) { throw AgentError("permission_denied", "请在手机上授予读取权限") }
        return JSONObject().put("items", items).put("nextCursor", next ?: JSONObject.NULL)
    }

    private fun granted(permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    private fun requirePermission(permission: String) {
        if (!granted(permission)) throw AgentError("permission_denied", "请在手机上授予对应权限")
    }
}
