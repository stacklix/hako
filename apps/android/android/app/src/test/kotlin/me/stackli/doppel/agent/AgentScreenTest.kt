package me.stackli.doppel.agent

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.PowerManager
import android.view.Display
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.time.Instant

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class AgentScreenTest {
    @Test fun everyDisplayStateIsKeptSeparateFromInteractivity() {
        val states = mapOf(Display.STATE_ON to "on", Display.STATE_OFF to "off",
            Display.STATE_DOZE to "doze", Display.STATE_DOZE_SUSPEND to "doze_suspend",
            Display.STATE_ON_SUSPEND to "on_suspend", Display.STATE_VR to "vr", Display.STATE_UNKNOWN to "unknown")
        for ((state, label) in states) {
            for (interactive in listOf(false, true)) {
                val data = AgentScreen.fromState(state, interactive)
                assertEquals(label, data.getString("displayState"))
                assertEquals(interactive, data.getBoolean("interactive"))
                assertNotNull(Instant.parse(data.getString("sampledAt")))
            }
        }
        assertEquals("unknown", AgentScreen.fromState(999, false).getString("displayState"))
    }

    @Test fun dispatcherReadsMainDisplayAndRejectsControlParameters() {
        val app = RuntimeEnvironment.getApplication()
        val display = app.getSystemService(DisplayManager::class.java).getDisplay(Display.DEFAULT_DISPLAY)
        val power = app.getSystemService(PowerManager::class.java)
        shadowOf(display).setState(Display.STATE_OFF)
        shadowOf(power).setIsInteractive(true)
        val data = AgentDispatcher(app).invoke(AgentScreen.COMMAND, 1, JSONObject())
        assertEquals("off", data.getString("displayState"))
        assertTrue(data.getBoolean("interactive"))
        assertThrows(AgentError::class.java) {
            AgentDispatcher(app).invoke(AgentScreen.COMMAND, 1, JSONObject().put("screenOn", true))
        }
        assertThrows(AgentError::class.java) { AgentDispatcher(app).invoke(AgentScreen.COMMAND, 2, JSONObject()) }
    }
}
