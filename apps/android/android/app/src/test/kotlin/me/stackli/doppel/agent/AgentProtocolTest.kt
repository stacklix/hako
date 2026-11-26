package me.stackli.doppel.agent

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class AgentProtocolTest {
    @Test fun aggregateNeverReadsHistoryOrRunsActions() {
        val calls = mutableListOf<String>()
        val data = AgentProtocol.aggregate {
            calls.add(it)
            if (it == "query.telephony.sims") throw AgentError("permission_denied", "未授权")
            JSONObject().put("platform", "android")
        }.getJSONObject("data")
        assertEquals(listOf("query.device.status", AgentStorage.COMMAND, AgentBattery.COMMAND, AgentWifi.COMMAND, AgentScreen.COMMAND, "query.network.lan", "query.telephony.sims"), calls)
        assertEquals("android", data.getJSONObject("query.device.status").getJSONObject("result").getString("platform"))
        assertEquals("permission_denied", data.getJSONObject("query.telephony.sims").getJSONObject("error").getString("code"))
        assertFalse(data.has("query.sms.messages"))
        assertFalse(data.has("query.telephony.calls"))
        assertFalse(data.has("query.device.operation"))
    }

    @Test fun challengeBindsServerAccountKeyAndNonce() {
        val payload = "hako-agent-auth/v4\nhttps://example.com\nowner\nkey\nnonce".toByteArray()
        AgentProtocol.checkChallenge(payload, "https://example.com", "owner", "key")
        assertThrows(AgentError::class.java) { AgentProtocol.checkChallenge(payload, "https://other.com", "owner", "key") }
        assertThrows(AgentError::class.java) { AgentProtocol.checkChallenge(payload, "https://example.com", "other", "key") }
        assertThrows(AgentError::class.java) { AgentProtocol.checkChallenge(payload, "https://example.com", "owner", "other") }
        assertThrows(AgentError::class.java) { AgentProtocol.checkChallenge(payload.copyOf(payload.size - 5), "https://example.com", "owner", "key") }
    }

    @Test fun originRejectsCredentialsPathsAndCleartext() {
        assertEquals("https://example.com", AgentProtocol.origin("https://example.com:443/"))
        for (value in listOf("http://example.com", "https://user:pass@example.com", "https://example.com/api", "https://example.com?token=x")) {
            assertThrows(AgentError::class.java) { AgentProtocol.origin(value) }
        }
    }

    @Test fun paginationAndEnvelopeAreStrict() {
        assertEquals(20, AgentProtocol.limit(JSONObject()))
        assertEquals(42L, AgentProtocol.cursor(JSONObject().put("cursor", "42")))
        for (limit in listOf(0, 51, 1.5, "20")) {
            assertThrows(AgentError::class.java) { AgentProtocol.limit(JSONObject().put("limit", limit)) }
        }
        assertThrows(AgentError::class.java) { AgentProtocol.cursor(JSONObject().put("cursor", "0 OR 1=1")) }
        val valid = JSONObject("""{"type":"request","id":"r","method":"query.all","version":1,"params":{}}""")
        assertEquals("query.all", AgentProtocol.request(valid).first)
        assertThrows(AgentError::class.java) { AgentProtocol.request(JSONObject(valid.toString()).put("version", "1")) }
        assertThrows(AgentError::class.java) { AgentProtocol.request(JSONObject(valid.toString()).put("params", org.json.JSONArray())) }
        assertThrows(AgentError::class.java) { AgentProtocol.request(JSONObject(valid.toString()).put("unexpected", true)) }
    }

    @Test fun serverVersionUsesDeclaredCompatibilityLine() {
        assertEquals("0.9.0", AgentProtocol.MINIMUM_SERVER)
        assertTrue(AgentProtocol.compatibleServer("0.9.0"))
        assertTrue(AgentProtocol.compatibleServer("0.9.1"))
        assertTrue(AgentProtocol.compatibleServer("0.9.20"))
        for (version in listOf("0.8.99", "0.10.0", "0.9", "0.9.0-beta", "0.9.-1", "0.09.0", "0.9.2147483648")) {
            assertFalse(AgentProtocol.compatibleServer(version))
        }
    }
}
