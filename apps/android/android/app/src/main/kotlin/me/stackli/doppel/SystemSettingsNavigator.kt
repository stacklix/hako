package me.stackli.doppel

import android.app.Activity
import android.app.NotificationManager
import android.content.ActivityNotFoundException
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings

internal class SystemSettingsNavigator(private val activity: Activity) {
    fun status(): Map<String, Boolean> = mapOf(
        // OEM self-start state is not a public Android API. Only report whether
        // its settings page is accessible; never infer that self-start is on.
        "autoStartAvailable" to available("autoStart"),
        "backgroundAvailable" to available("background"),
        "batteryExempt" to (activity.getSystemService(PowerManager::class.java)
            ?.isIgnoringBatteryOptimizations(activity.packageName) == true),
        "notificationsEnabled" to (activity.getSystemService(NotificationManager::class.java)
            ?.areNotificationsEnabled() == true),
    )

    fun intent(target: String): Intent? = when (target) {
        "autoStart" -> if (Build.MANUFACTURER.equals("Xiaomi", ignoreCase = true)) {
            Intent().setComponent(ComponentName("com.miui.securitycenter",
                "com.miui.permcenter.autostart.AutoStartManagementActivity"))
        } else null
        "background" -> if (Build.MANUFACTURER.equals("Xiaomi", ignoreCase = true)) {
            Intent().setComponent(ComponentName("com.miui.powerkeeper",
                "com.miui.powerkeeper.ui.HiddenAppsConfigActivity"))
                .putExtra("package_name", activity.packageName)
                .putExtra("package_label", activity.applicationInfo.loadLabel(activity.packageManager).toString())
        } else null
        "battery" -> Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS)
        "notifications" -> Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
            .putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
        "application" -> Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
            Uri.parse("package:${activity.packageName}"))
        else -> throw IllegalArgumentException("未知的系统设置入口")
    }

    private fun available(target: String): Boolean {
        val next = intent(target) ?: return false
        val info = activity.packageManager.resolveActivity(next, 0)?.activityInfo ?: return false
        return info.enabled && info.exported && (info.permission == null ||
            activity.checkSelfPermission(info.permission) == PackageManager.PERMISSION_GRANTED)
    }

    fun open(target: String) {
        val next = intent(target) ?: throw ActivityNotFoundException("此系统未提供该设置快捷入口")
        activity.startActivity(next)
    }
}
