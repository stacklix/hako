package me.stackli.doppel.agent

import android.content.Context
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowStatFs
import java.time.Instant

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class AgentStorageTest {
    @Test fun reportsAppAvailableSpaceExcludingReservedBlocks() {
        val context = RuntimeEnvironment.getApplication() as Context
        ShadowStatFs.registerStats(context.filesDir, 100, 40, 30)
        val data = AgentDispatcher(context).invoke(AgentStorage.COMMAND, 1, JSONObject())
        assertEquals(100L * ShadowStatFs.BLOCK_SIZE, data.getLong("storageTotalBytes"))
        assertEquals(30L * ShadowStatFs.BLOCK_SIZE, data.getLong("storageAvailableBytes"))
        assertNotNull(Instant.parse(data.getString("sampledAt")))
        assertFalse(data.has("path"))
        assertThrows(AgentError::class.java) {
            AgentDispatcher(context).invoke(AgentStorage.COMMAND, 1, JSONObject().put("path", "/"))
        }
    }

    @Test fun fullVolumeIsValidButInvalidCapacityFailsIndependently() {
        val context = RuntimeEnvironment.getApplication() as Context
        ShadowStatFs.registerStats(context.filesDir, 100, 0, 0)
        assertEquals(0L, AgentStorage.snapshot(context).getLong("storageAvailableBytes"))
        ShadowStatFs.registerStats(context.filesDir, 0, 0, 0)
        val error = assertThrows(AgentError::class.java) { AgentStorage.snapshot(context) }
        assertEquals("storage_unavailable", error.code)
        val all = AgentProtocol.aggregate { method ->
            if (method == AgentStorage.COMMAND) AgentStorage.snapshot(context) else JSONObject().put("ok", true)
        }.getJSONObject("data")
        assertTrue(all.getJSONObject("query.device.status").has("result"))
        assertEquals("storage_unavailable", all.getJSONObject(AgentStorage.COMMAND).getJSONObject("error").getString("code"))
    }
}
