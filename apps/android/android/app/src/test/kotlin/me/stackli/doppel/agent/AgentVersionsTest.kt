package me.stackli.doppel.agent

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.io.IOException
import java.time.Instant

class AgentVersionsTest {
    @Test fun versionAdministrationDoesNotNeedMainProcessAndRejectsUnexpectedInput() {
        var calls = 0
        val local = object : AgentCommands {
            override fun invoke(method: String, version: Int, params: JSONObject): JSONObject {
                calls++
                throw AgentError("main_process_unavailable", "主进程未运行")
            }
        }
        val commands = AgentGuardianCommands(local, AgentVersions("1.0.13", "1.0.13+14", { null }))
        val data = commands.invoke(AgentVersions.COMMAND, 1, JSONObject())
        assertEquals("1.0.13", data.getString("currentVersion"))
        assertEquals("1.0.13+14", data.getString("currentBuild"))
        assertEquals(AgentProtocol.MINIMUM_SERVER, data.getString("minimumServerVersion"))
        assertEquals("no_release", data.getString("latestCheckState"))
        assertTrue(data.isNull("latestVersion"))
        assertTrue(data.isNull("latestBuildId"))
        assertEquals(0, calls)
        for ((method, version, params) in listOf(
            Triple("admin.unknown", 1, JSONObject()), Triple(AgentVersions.COMMAND, 2, JSONObject()),
            Triple(AgentVersions.COMMAND, 1, JSONObject().put("extra", true)),
        )) assertThrows(AgentError::class.java) { commands.invoke(method, version, params) }
        assertEquals(0, calls)
        assertThrows(AgentError::class.java) { commands.invoke("query.device.status", 1, JSONObject()) }
        assertEquals(1, calls)
        assertTrue(AgentProtocol.capabilities.any { it.name == AgentVersions.COMMAND && !it.aggregate })
    }

    @Test fun cacheRetriesFailuresAndReturnsIndependentSnapshots() {
        var now = Instant.parse("2026-11-20T00:00:00Z")
        var calls = 0
        val versions = AgentVersions("1.0.13", "1.0.13+14", {
            if (++calls == 1) throw IOException("offline")
            AndroidAgentRelease("1.0.14", 15)
        }, { now })
        val failed = versions.read()
        assertEquals("unavailable", failed.getString("latestCheckState"))
        assertTrue(failed.isNull("latestVersion"))
        failed.put("currentVersion", "corrupted")
        now = now.plusSeconds(29)
        assertEquals("1.0.13", versions.read().getString("currentVersion"))
        assertEquals(1, calls)
        now = now.plusSeconds(1)
        val success = versions.read()
        assertEquals("available", success.getString("latestCheckState"))
        assertEquals("1.0.14", success.getString("latestVersion"))
        assertEquals(15L, success.getLong("latestBuildId"))
        assertEquals(now, Instant.parse(success.getString("latestCheckedAt")))
        now = now.plusSeconds(299)
        versions.read()
        assertEquals(2, calls)
        now = now.plusSeconds(1)
        versions.read()
        assertEquals(3, calls)
    }

    @Test fun releaseLookupExcludesWindowsDraftsAndUnpublishedOrUntrustedApks() {
        fun release(tag: String, asset: String = "Nami.apk", draft: Boolean = false, prerelease: Boolean = false,
                    url: String = "https://github.com/stacklix/hako/releases/download/$tag/$asset") =
            JSONObject().put("tag_name", tag).put("draft", draft).put("prerelease", prerelease)
                .put("assets", JSONArray().put(JSONObject().put("name", asset).put("browser_download_url", url)))
        val releases = JSONArray()
            .put(release("windows-agent-9999", "Kage.exe"))
            .put(release("android-agent-1.0.99-99", draft = true))
            .put(release("android-agent-1.0.98-98", prerelease = true))
            .put(release("android-agent-1.0.97-97", "source.zip"))
            .put(release("android-agent-1.0.96-96", url = "https://other.example/Nami.apk"))
        assertNull(GitHubAndroidReleases.parse(releases))
        releases.put(release("android-agent-1.0.9-10"))
            .put(release("android-agent-1.0.13-14"))
            .put(release("android-agent-1.0.13-15"))
        assertEquals(AndroidAgentRelease("1.0.13", 15), GitHubAndroidReleases.parse(releases))
    }
}
