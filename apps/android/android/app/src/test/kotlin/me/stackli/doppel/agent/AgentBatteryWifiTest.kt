package me.stackli.doppel.agent

import android.Manifest
import android.content.Context
import android.content.Intent
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.NetworkInfo
import android.net.wifi.WifiManager
import android.os.BatteryManager
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowNetwork
import org.robolectric.shadows.ShadowNetworkCapabilities
import org.robolectric.shadows.ShadowNetworkInfo
import org.robolectric.shadows.ShadowWifiInfo

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class AgentBatteryWifiTest {
    @Test fun batteryReadingsAreOnlyReturnedByTheBatteryQuery() {
        val app = RuntimeEnvironment.getApplication()
        app.sendStickyBroadcast(Intent(Intent.ACTION_BATTERY_CHANGED)
            .putExtra(BatteryManager.EXTRA_LEVEL, 7).putExtra(BatteryManager.EXTRA_SCALE, 10)
            .putExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_CHARGING))
        val dispatcher = AgentDispatcher(app)
        val status = dispatcher.invoke("query.device.status", 1, JSONObject())
        assertFalse(status.has("batteryPercent"))
        assertFalse(status.has("charging"))
        val battery = dispatcher.invoke(AgentBattery.COMMAND, 1, JSONObject())
        assertEquals(70, battery.getInt("levelPercent"))
        assertEquals("charging", battery.getString("state"))
    }

    @Test fun batteryUnitsAndChargingStateAreExplicit() {
        val intent = Intent(Intent.ACTION_BATTERY_CHANGED)
            .putExtra(BatteryManager.EXTRA_LEVEL, 7).putExtra(BatteryManager.EXTRA_SCALE, 10)
            .putExtra(BatteryManager.EXTRA_TEMPERATURE, 325).putExtra(BatteryManager.EXTRA_VOLTAGE, 4123)
            .putExtra(BatteryManager.EXTRA_PLUGGED, BatteryManager.BATTERY_PLUGGED_USB)
            .putExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_CHARGING)
            .putExtra(BatteryManager.EXTRA_HEALTH, BatteryManager.BATTERY_HEALTH_GOOD)
        val data = AgentBattery.fromIntent(intent, 550.0)
        assertEquals(70, data.getInt("levelPercent"))
        assertEquals(32.5, data.getDouble("temperatureCelsius"), 0.001)
        assertEquals(4.123, data.getDouble("voltageVolts"), 0.001)
        assertEquals(550.0, data.getDouble("currentMilliamps"), 0.001)
        assertEquals("usb", data.getString("powerSource"))
        assertEquals("charging", data.getString("state"))
        assertEquals("good", data.getString("health"))
        val missing = AgentBattery.fromIntent(Intent(), null)
        for (key in listOf("levelPercent", "temperatureCelsius", "voltageVolts", "currentMilliamps")) assertTrue(missing.isNull(key))
        assertEquals("unknown", missing.getString("state"))
    }

    @Test fun wifiKeepsOtherReadingsWhenNameIsNotAuthorized() {
        val app = RuntimeEnvironment.getApplication()
        val connectivity = app.getSystemService(ConnectivityManager::class.java)
        val network = ShadowNetwork.newInstance(42)
        shadowOf(connectivity).clearAllNetworks()
        shadowOf(connectivity).addNetwork(network, ShadowNetworkInfo.newInstance(NetworkInfo.DetailedState.CONNECTED, ConnectivityManager.TYPE_WIFI, 0, true, true))
        val caps = ShadowNetworkCapabilities.newInstance()
        shadowOf(caps).addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
        shadowOf(caps).addCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
        shadowOf(connectivity).setNetworkCapabilities(network, caps)
        val info = ShadowWifiInfo.newInstance()
        shadowOf(info).setSSID("Test Network")
        shadowOf(info).setRssi(-55)
        shadowOf(info).setLinkSpeed(433)
        shadowOf(info).setFrequency(5180)
        shadowOf(app.getSystemService(WifiManager::class.java)).setConnectionInfo(info)
        shadowOf(app.getSystemService(LocationManager::class.java)).setLocationEnabled(true)
        shadowOf(app).denyPermissions(Manifest.permission.ACCESS_FINE_LOCATION)
        val hidden = AgentWifi.snapshot(app)
        assertTrue(hidden.getBoolean("connected"))
        assertTrue(hidden.isNull("ssid"))
        assertEquals("permission_required", hidden.getString("ssidState"))
        assertEquals(-55, hidden.getInt("rssiDbm"))
        assertEquals(433, hidden.getInt("linkSpeedMbps"))
        assertTrue(hidden.getBoolean("internetValidated"))
        shadowOf(app).grantPermissions(Manifest.permission.ACCESS_FINE_LOCATION)
        val named = AgentWifi.snapshot(app)
        assertEquals("Test Network", named.getString("ssid"))
        assertEquals("available", named.getString("ssidState"))
        shadowOf(app.getSystemService(LocationManager::class.java)).setLocationEnabled(false)
        val disabled = AgentWifi.snapshot(app)
        assertTrue(disabled.isNull("ssid"))
        assertEquals("location_disabled", disabled.getString("ssidState"))
        assertFalse(named.has("bssid")); assertFalse(named.has("password")); assertFalse(named.has("latitude"))
        assertThrows(AgentError::class.java) { AgentDispatcher(app).invoke(AgentWifi.COMMAND, 1, JSONObject().put("scan", true)) }
    }

    @Test fun disconnectedWifiNeverReportsStaleReadings() {
        val app = RuntimeEnvironment.getApplication()
        shadowOf(app.getSystemService(ConnectivityManager::class.java)).clearAllNetworks()
        val data = AgentWifi.snapshot(app)
        assertFalse(data.getBoolean("connected"))
        assertEquals("not_connected", data.getString("ssidState"))
        for (key in listOf("ssid", "rssiDbm", "linkSpeedMbps", "frequencyMhz")) assertTrue(data.isNull(key))
        assertEquals("含 空格", AgentWifi.cleanSsid("\"含 空格\""))
        assertNull(AgentWifi.cleanSsid(WifiManager.UNKNOWN_SSID))
        assertNull(AgentWifi.cleanSsid("\"\""))
    }
}
