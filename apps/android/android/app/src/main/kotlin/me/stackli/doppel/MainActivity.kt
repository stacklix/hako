package me.stackli.doppel

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.os.Build
import android.provider.Telephony
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject

class MainActivity : FlutterActivity() {
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
                "getSnapshot" -> result.success(buildSnapshot())
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
    }

    override fun onDestroy() {
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
            Manifest.permission.SEND_SMS,
            Manifest.permission.CALL_PHONE,
            Manifest.permission.READ_PHONE_STATE,
            Manifest.permission.READ_PHONE_NUMBERS,
        )
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
