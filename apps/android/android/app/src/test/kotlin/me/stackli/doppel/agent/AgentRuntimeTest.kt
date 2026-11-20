package me.stackli.doppel.agent

import android.content.Context
import me.stackli.doppel.DoppelSnapshotStore
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class AgentRuntimeTest {
    @Test fun connectionEventsAreDurableBoundedAndVisibleInSnapshot() {
        val context = RuntimeEnvironment.getApplication() as Context
        AgentSettingsStore.writeFile(context, "hako-agent-status.json", org.json.JSONObject())
        AgentRuntime.update(context, "connecting", "正在连接 Sora")
        AgentRuntime.update(context, "connecting", "正在连接 Sora")
        var snapshot = AgentRuntime.snapshot(context)
        assertEquals(1, snapshot.getJSONArray("events").length())
        assertEquals("connecting", snapshot.getString("state"))
        for (index in 1..105) AgentRuntime.update(context, "retrying", "连接超时，第 $index 次")
        snapshot = AgentRuntime.snapshot(context)
        val events = snapshot.getJSONArray("events")
        assertEquals(100, events.length())
        assertEquals("agent_connection", events.getJSONObject(0).getString("type"))
        assertTrue(events.getJSONObject(99).getString("detail").contains("105"))
        val visible = DoppelSnapshotStore.buildSnapshotJson(context).getJSONArray("events")
        assertEquals(100, (0 until visible.length()).count { visible.getJSONObject(it).optString("type") == "agent_connection" })
        assertFalse(snapshot.toString().contains("signature"))
        assertFalse(snapshot.toString().contains("publicKey"))
    }
}
