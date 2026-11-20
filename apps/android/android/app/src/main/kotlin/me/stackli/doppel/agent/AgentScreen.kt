package me.stackli.doppel.agent

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.PowerManager
import android.view.Display
import org.json.JSONObject
import java.time.Instant

internal object AgentScreen {
    const val COMMAND = "query.device.screen"

    fun snapshot(context: Context): JSONObject {
        val displays = context.getSystemService(DisplayManager::class.java)
        val power = context.getSystemService(PowerManager::class.java)
            ?: throw AgentError("screen_unavailable", "系统暂未提供屏幕状态")
        val display = displays?.getDisplay(Display.DEFAULT_DISPLAY)
        return fromState(display?.state ?: Display.STATE_UNKNOWN, power.isInteractive)
    }

    internal fun fromState(state: Int, interactive: Boolean): JSONObject {
        // Interactivity and panel power are different: proximity can turn the
        // panel off during a call while the device stays interactive.
        val name = when (state) {
            Display.STATE_ON -> "on"
            Display.STATE_OFF -> "off"
            Display.STATE_DOZE -> "doze"
            Display.STATE_DOZE_SUSPEND -> "doze_suspend"
            Display.STATE_ON_SUSPEND -> "on_suspend"
            Display.STATE_VR -> "vr"
            else -> "unknown"
        }
        return JSONObject().put("displayState", name).put("interactive", interactive)
            .put("sampledAt", Instant.now().toString())
    }
}
