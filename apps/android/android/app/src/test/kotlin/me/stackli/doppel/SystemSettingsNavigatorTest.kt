package me.stackli.doppel

import android.app.Activity
import android.content.pm.ActivityInfo
import android.content.pm.ResolveInfo
import android.provider.Settings
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowBuild

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class SystemSettingsNavigatorTest {
    private lateinit var activity: Activity
    private lateinit var navigator: SystemSettingsNavigator

    @Before fun prepare() {
        activity = Robolectric.buildActivity(Activity::class.java).setup().get()
        navigator = SystemSettingsNavigator(activity)
        ShadowBuild.setManufacturer("Xiaomi")
    }

    @Test fun systemIntentsAreScopedToDoppel() {
        assertEquals("package:${activity.packageName}", navigator.intent("application")!!.dataString)
        assertEquals(activity.packageName, navigator.intent("notifications")!!.getStringExtra(Settings.EXTRA_APP_PACKAGE))
        assertEquals(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS, navigator.intent("battery")!!.action)
        assertEquals(activity.packageName, navigator.intent("background")!!.getStringExtra("package_name"))
        assertEquals("com.miui.securitycenter", navigator.intent("autoStart")!!.component!!.packageName)
        assertThrows(IllegalArgumentException::class.java) { navigator.intent("unknown") }
    }

    @Test fun oemEntryNeedsAnExportedAccessibleActivity() {
        val intent = navigator.intent("autoStart")!!
        val info = ActivityInfo().apply {
            packageName = intent.component!!.packageName
            name = intent.component!!.className
            enabled = true
            exported = true
        }
        shadowOf(activity.packageManager).addResolveInfoForIntent(intent, ResolveInfo().apply { activityInfo = info })
        assertEquals(true, navigator.status()["autoStartAvailable"])
        info.exported = false
        assertEquals(false, navigator.status()["autoStartAvailable"])
    }

    @Test fun doesNotPretendUnsupportedDevicesHaveAnAutostartPage() {
        ShadowBuild.setManufacturer("Other")
        assertNull(navigator.intent("autoStart"))
        assertNull(navigator.intent("background"))
        assertEquals(false, navigator.status()["autoStartAvailable"])
        assertFalse(navigator.status().containsKey("autoStartEnabled"))
    }

    @Test fun shortcutOnlyOpensTheRequestedSettingsPage() {
        navigator.open("notifications")
        val intent = shadowOf(activity).nextStartedActivity
        assertEquals(Settings.ACTION_APP_NOTIFICATION_SETTINGS, intent.action)
        assertEquals(activity.packageName, intent.getStringExtra(Settings.EXTRA_APP_PACKAGE))
    }
}
