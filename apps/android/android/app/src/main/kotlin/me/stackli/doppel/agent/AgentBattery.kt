package me.stackli.doppel.agent

import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.BatteryManager
import org.json.JSONObject
import java.time.Instant

internal object AgentBattery {
    const val COMMAND = "query.device.battery"

    fun snapshot(context: Context): JSONObject {
        val intent = context.registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED))
            ?: throw AgentError("battery_unavailable", "系统暂未提供电池信息")
        val current = context.getSystemService(BatteryManager::class.java)
            ?.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW)
            ?.takeUnless { it == Int.MIN_VALUE }?.div(1000.0)
        return fromIntent(intent, current)
    }

    internal fun fromIntent(intent: Intent, currentMa: Double?): JSONObject {
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, -1)
        val percent = if (scale > 0 && level in 0..scale) level.toLong() * 100 / scale else null
        val temperature = if (intent.hasExtra(BatteryManager.EXTRA_TEMPERATURE))
            intent.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Int.MIN_VALUE).takeIf { it in -500..1000 }?.div(10.0) else null
        val voltage = intent.getIntExtra(BatteryManager.EXTRA_VOLTAGE, 0).takeIf { it > 0 }?.div(1000.0)
        val plugged = intent.getIntExtra(BatteryManager.EXTRA_PLUGGED, -1)
        val source = when {
            plugged < 0 -> "unknown"
            plugged == 0 -> "battery"
            plugged and BatteryManager.BATTERY_PLUGGED_AC != 0 -> "ac"
            plugged and BatteryManager.BATTERY_PLUGGED_USB != 0 -> "usb"
            plugged and BatteryManager.BATTERY_PLUGGED_WIRELESS != 0 -> "wireless"
            plugged and 8 != 0 -> "dock"
            else -> "other"
        }
        val state = when (intent.getIntExtra(BatteryManager.EXTRA_STATUS, -1)) {
            BatteryManager.BATTERY_STATUS_CHARGING -> "charging"
            BatteryManager.BATTERY_STATUS_DISCHARGING -> "discharging"
            BatteryManager.BATTERY_STATUS_FULL -> "full"
            BatteryManager.BATTERY_STATUS_NOT_CHARGING -> "not_charging"
            else -> "unknown"
        }
        val health = when (intent.getIntExtra(BatteryManager.EXTRA_HEALTH, -1)) {
            BatteryManager.BATTERY_HEALTH_GOOD -> "good"
            BatteryManager.BATTERY_HEALTH_OVERHEAT -> "overheat"
            BatteryManager.BATTERY_HEALTH_DEAD -> "dead"
            BatteryManager.BATTERY_HEALTH_OVER_VOLTAGE -> "over_voltage"
            BatteryManager.BATTERY_HEALTH_UNSPECIFIED_FAILURE -> "failure"
            BatteryManager.BATTERY_HEALTH_COLD -> "cold"
            else -> "unknown"
        }
        return JSONObject().put("levelPercent", percent ?: JSONObject.NULL)
            .put("temperatureCelsius", temperature ?: JSONObject.NULL)
            .put("voltageVolts", voltage ?: JSONObject.NULL)
            .put("currentMilliamps", currentMa ?: JSONObject.NULL)
            .put("state", state).put("powerSource", source).put("health", health)
            .put("sampledAt", Instant.now().toString())
    }
}
