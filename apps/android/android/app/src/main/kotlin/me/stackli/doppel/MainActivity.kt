package me.stackli.doppel

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.os.Build
import android.content.ActivityNotFoundException
import android.provider.Telephony
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import me.stackli.doppel.agent.AgentError
import me.stackli.doppel.agent.AgentKeys
import me.stackli.doppel.agent.AgentService
import me.stackli.doppel.agent.AgentSettingsStore
import me.stackli.doppel.agent.AgentWifi
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val agentExecutor = Executors.newSingleThreadExecutor()
    private var pendingPermissionsResult: MethodChannel.Result? = null
    private var platformChannel: MethodChannel? = null
    private var snapshotReceiverRegistered = false
    private var foregroundSmsReceiverRegistered = false
    private val foregroundSmsReceiver = SmsReceiver()
    private val snapshotReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            if (intent.action != ACTION_DOPPEL_SNAPSHOT_CHANGED) {
                return
            }
            pushSnapshotToFlutter()
        }
    }
    private val preferenceChangeListener =
        SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
            if (key != KEY_EVENTS && key != KEY_CONFIG) {
                return@OnSharedPreferenceChangeListener
            }
            pushSnapshotToFlutter()
        }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        platformChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CHANNEL_NAME,
        )
        platformChannel?.setMethodCallHandler { call, result ->
            when (call.method) {
                "getAgentSettings", "saveAgentSettings", "generateAgentKey" -> {
                    agentExecutor.execute {
                        try {
                            val store = AgentSettingsStore(applicationContext)
                            if (call.method == "saveAgentSettings") store.save(toJsonObject(call.arguments))
                            if (call.method == "generateAgentKey") AgentKeys.generate()
                            val snapshot = store.snapshot().toMapValue()
                            runOnUiThread {
                                if (call.method == "saveAgentSettings") AgentService.sync(this, restart = true)
                                result.success(snapshot)
                            }
                        } catch (error: AgentError) {
                            runOnUiThread { result.error(error.code, error.message, null) }
                        } catch (_: Exception) {
                            runOnUiThread { result.error("agent_settings_failed", "Agent 设置操作失败，请重试", null) }
                        }
                    }
                }
                "getSystemSettings" -> {
                    try { result.success(SystemSettingsNavigator(this).status()) }
                    catch (_: Exception) { result.error("settings_unavailable", "无法读取系统设置状态，请重试", null) }
                }
                "openBatterySettings", "openSystemSettings" -> {
                    try {
                        val target = if (call.method == "openBatterySettings") "battery"
                            else call.argument<String>("target").orEmpty()
                        SystemSettingsNavigator(this).open(target)
                        result.success(null)
                    } catch (_: ActivityNotFoundException) {
                        result.error("settings_unavailable", "此设置页不可用，请在应用详情中查看自启动、后台运行或权限设置", null)
                    } catch (_: SecurityException) {
                        result.error("settings_unavailable", "系统不允许直接打开此页面，请从手机系统设置进入", null)
                    } catch (_: IllegalArgumentException) {
                        result.error("settings_unavailable", "未知的系统设置入口", null)
                    }
                }
                "getSnapshot" -> result.success(buildSnapshot())
                "getWifiPermissions" -> result.success(AgentWifi.permissions(this).toMapValue())
                "openWifiLocationSettings" -> {
                    try {
                        startActivity(Intent(Settings.ACTION_LOCATION_SOURCE_SETTINGS))
                        result.success(true)
                    } catch (_: ActivityNotFoundException) {
                        result.error("settings_unavailable", "请从手机系统设置开启定位服务", null)
                    }
                }
                "requestWifiPermissions" -> {
                    if (pendingPermissionsResult != null) {
                        result.error("permission_request_pending", "正在等待其他权限请求完成", null)
                        return@setMethodCallHandler
                    }
                    val fine = checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
                    val background = Build.VERSION.SDK_INT < 29 || checkSelfPermission(Manifest.permission.ACCESS_BACKGROUND_LOCATION) == PackageManager.PERMISSION_GRANTED
                    when {
                        !fine -> {
                            pendingPermissionsResult = result
                            requestPermissions(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION), REQUEST_PERMISSIONS_CODE)
                        }
                        !background && Build.VERSION.SDK_INT == 29 -> {
                            pendingPermissionsResult = result
                            requestPermissions(arrayOf(Manifest.permission.ACCESS_BACKGROUND_LOCATION), REQUEST_PERMISSIONS_CODE)
                        }
                        else -> {
                            try {
                                startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName")))
                                result.success(true)
                            } catch (_: ActivityNotFoundException) {
                                result.error("settings_unavailable", "请从手机系统设置进入 Nami 的定位权限页面", null)
                            }
                        }
                    }
                }
                "saveConfig" -> {
                    mergeConfig(call.arguments)
                    RemoteControlService.sync(this)
                    result.success(true)
                }
                "requestRequiredPermissions" -> {
                    if (pendingPermissionsResult != null) {
                        result.error(
                            "permission_request_pending",
                            "A permission request is already in progress.",
                            null,
                        )
                        return@setMethodCallHandler
                    }
                    pendingPermissionsResult = result
                    requestPermissions(REQUIRED_PERMISSIONS, REQUEST_PERMISSIONS_CODE)
                }
                else -> result.notImplemented()
            }
        }
        prefs().registerOnSharedPreferenceChangeListener(preferenceChangeListener)
        registerSnapshotReceiver()
        registerForegroundSmsReceiver()
        RemoteControlStore.syncDirectBootConfig(this)
        SmsPipeline.seedInboxBackfillCursor(this)
        RemoteControlService.sync(this)
        AgentService.sync(this)
    }

    override fun onDestroy() {
        agentExecutor.shutdown()
        prefs().unregisterOnSharedPreferenceChangeListener(preferenceChangeListener)
        if (snapshotReceiverRegistered) {
            unregisterReceiver(snapshotReceiver)
            snapshotReceiverRegistered = false
        }
        if (foregroundSmsReceiverRegistered) {
            unregisterReceiver(foregroundSmsReceiver)
            foregroundSmsReceiverRegistered = false
        }
        platformChannel = null
        super.onDestroy()
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != REQUEST_PERMISSIONS_CODE) {
            return
        }
        pendingPermissionsResult?.success(true)
        pendingPermissionsResult = null
    }

    private fun buildSnapshot(): Map<String, Any?> {
        return DoppelSnapshotStore.buildSnapshotMap(this)
    }

    private fun readConfigMap(): Map<String, Any?> {
        return RemoteControlStore.readConfigJson(this).toMapValue()
    }

    private fun mergeConfig(arguments: Any?) {
        val existing = JSONObject(prefs().getString(KEY_CONFIG, "{}") ?: "{}")
        val incoming = toJsonObject(arguments)
        mergeJsonObjects(existing, incoming)
        prefs().edit().putString(KEY_CONFIG, existing.toString()).apply()
        RemoteControlStore.syncDirectBootConfig(this)
        SmsPipeline.seedInboxBackfillCursor(this)
    }

    private fun pushSnapshotToFlutter() {
        runOnUiThread {
            platformChannel?.invokeMethod("snapshotChanged", buildSnapshot())
        }
    }

    private fun registerSnapshotReceiver() {
        if (snapshotReceiverRegistered) {
            return
        }
        val filter = IntentFilter(ACTION_DOPPEL_SNAPSHOT_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(snapshotReceiver, filter, RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(snapshotReceiver, filter)
        }
        snapshotReceiverRegistered = true
    }

    private fun registerForegroundSmsReceiver() {
        if (foregroundSmsReceiverRegistered) {
            return
        }
        val filter = IntentFilter(Telephony.Sms.Intents.SMS_RECEIVED_ACTION)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(foregroundSmsReceiver, filter, RECEIVER_EXPORTED)
        } else {
            registerReceiver(foregroundSmsReceiver, filter)
        }
        foregroundSmsReceiverRegistered = true
    }

    private fun prefs() = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    companion object {
        private const val CHANNEL_NAME = "doppel/platform"
        private const val PREFS_NAME = "doppel"
        private const val REQUEST_PERMISSIONS_CODE = 4201
        const val KEY_CONFIG = "config_json"
        const val KEY_EVENTS = "events_json"
        private val REQUIRED_PERMISSIONS = arrayOf(
            Manifest.permission.RECEIVE_SMS,
            Manifest.permission.READ_SMS,
            Manifest.permission.READ_CALL_LOG,
            Manifest.permission.SEND_SMS,
            Manifest.permission.CALL_PHONE,
            Manifest.permission.READ_PHONE_STATE,
            Manifest.permission.READ_PHONE_NUMBERS,
        ) + if (Build.VERSION.SDK_INT >= 33) arrayOf(Manifest.permission.POST_NOTIFICATIONS) else emptyArray()
    }
}

private fun mergeJsonObjects(target: JSONObject, incoming: JSONObject) {
    incoming.keys().forEach { key ->
        val incomingValue = incoming.get(key)
        if (incomingValue == JSONObject.NULL) {
            return@forEach
        }
        val existingValue = target.opt(key)
        if (existingValue is JSONObject && incomingValue is JSONObject) {
            mergeJsonObjects(existingValue, incomingValue)
        } else {
            target.put(key, incomingValue)
        }
    }
}

private fun toJsonObject(value: Any?): JSONObject {
    val json = JSONObject()
    if (value !is Map<*, *>) {
        return json
    }

    value.forEach { (key, item) ->
        json.put(key?.toString().orEmpty(), toJsonValue(item))
    }
    return json
}

private fun toJsonArray(value: List<*>): JSONArray {
    val json = JSONArray()
    value.forEach { item -> json.put(toJsonValue(item)) }
    return json
}

private fun toJsonValue(value: Any?): Any? {
    return when (value) {
        null -> JSONObject.NULL
        is Map<*, *> -> toJsonObject(value)
        is List<*> -> toJsonArray(value)
        else -> value
    }
}
