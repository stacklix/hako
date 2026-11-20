package me.stackli.doppel.agent

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.location.LocationManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.wifi.WifiManager
import android.os.Build
import org.json.JSONObject
import java.time.Instant

internal object AgentWifi {
    const val COMMAND = "query.network.wifi"
    fun permissions(context: Context): JSONObject = JSONObject()
        .put("preciseLocationGranted", granted(context, Manifest.permission.ACCESS_FINE_LOCATION))
        .put("backgroundLocationGranted", Build.VERSION.SDK_INT < 29 || granted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION))
        .put("locationEnabled", locationEnabled(context))

    @Suppress("DEPRECATION")
    fun snapshot(context: Context): JSONObject {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
            ?: throw AgentError("wifi_unavailable", "系统暂未提供 Wi-Fi 信息")
        val networks = connectivity.allNetworks.mapNotNull { connectivity.getNetworkCapabilities(it) }
            .filter { it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) }
        val capabilities = connectivity.getNetworkCapabilities(connectivity.activeNetwork)?.takeIf { it.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) }
            ?: networks.firstOrNull { it.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) } ?: networks.firstOrNull()
        val connected = capabilities != null
        val fine = granted(context, Manifest.permission.ACCESS_FINE_LOCATION)
        val background = Build.VERSION.SDK_INT < 29 || granted(context, Manifest.permission.ACCESS_BACKGROUND_LOCATION)
        val locationEnabled = locationEnabled(context)
        // This on-demand API is available throughout the app's supported API range.
        // It returns the Internet Wi-Fi connection and does not scan nearby networks.
        val info = if (connected) context.applicationContext.getSystemService(WifiManager::class.java)?.connectionInfo else null
        val name = if (fine && locationEnabled) cleanSsid(info?.ssid) else null
        val state = when {
            !connected -> "not_connected"
            !fine -> "permission_required"
            !locationEnabled -> "location_disabled"
            name != null -> "available"
            !background -> "background_permission_required"
            else -> "unavailable"
        }
        val rssi = info?.rssi?.takeIf { it in -126..-1 }
        return JSONObject().put("connected", connected).put("ssid", name ?: JSONObject.NULL)
            .put("ssidState", state).put("rssiDbm", rssi ?: JSONObject.NULL)
            .put("signalLevel", rssi?.let { WifiManager.calculateSignalLevel(it, 5) } ?: JSONObject.NULL)
            .put("linkSpeedMbps", info?.linkSpeed?.takeIf { it > 0 } ?: JSONObject.NULL)
            .put("frequencyMhz", info?.frequency?.takeIf { it > 0 } ?: JSONObject.NULL)
            .put("internetValidated", capabilities?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true)
            .put("sampledAt", Instant.now().toString())
    }
    internal fun cleanSsid(value: String?): String? {
        if (value == null || value == WifiManager.UNKNOWN_SSID) return null
        val name = if (value.length >= 2 && value.first() == '"' && value.last() == '"') value.substring(1, value.length - 1) else value
        return name.takeIf { it.isNotEmpty() && it != WifiManager.UNKNOWN_SSID }
    }
    private fun granted(context: Context, permission: String) = context.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
    private fun locationEnabled(context: Context): Boolean {
        val location = context.getSystemService(LocationManager::class.java) ?: return false
        return location.isProviderEnabled(LocationManager.GPS_PROVIDER) || location.isProviderEnabled(LocationManager.NETWORK_PROVIDER)
    }
}
