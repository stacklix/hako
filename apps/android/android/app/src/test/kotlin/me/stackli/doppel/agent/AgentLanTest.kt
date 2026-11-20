package me.stackli.doppel.agent

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

class AgentLanTest {
    private val key = ByteArray(32) { it.toByte() }
    private fun body(method: String, timestamp: Long = System.currentTimeMillis()): ByteArray {
        val plain = JSONObject().put("id", UUID.randomUUID().toString()).put("timestamp", timestamp)
            .put("method", method).put("version", 1).put("params", JSONObject()).toString().toByteArray()
        return JSONObject().put("version", 1).put("payload", Base64.getEncoder()
            .encodeToString(AgentLanCrypto.seal(key, plain, "request"))).toString().toByteArray()
    }
    @Test fun sharedCrossPlatformVectorAndAuthentication() {
        val vector = Base64.getDecoder().decode("AAECAwQFBgcICQoLC0OYO6aXrWj+bOfn0J0eAvG7p0CVCCsC7CiLRe9PkYVIZxJY51fa")
        assertEquals("LAN cross-platform test", AgentLanCrypto.open(key, vector, "request").toString(Charsets.UTF_8))
        assertThrows(Exception::class.java) { AgentLanCrypto.open(key, vector, "response") }
        vector[vector.lastIndex] = (vector.last().toInt() xor 1).toByte()
        assertThrows(Exception::class.java) { AgentLanCrypto.open(key, vector, "request") }
        assertThrows(Exception::class.java) { AgentLanCrypto.open(ByteArray(32), vector, "request") }
    }
    @Test fun encryptedQueriesNeverExecuteActionsAndRejectExpiredRequests() {
        val calls = AtomicInteger()
        val commands = object : AgentCommands {
            override fun invoke(method: String, version: Int, params: JSONObject): JSONObject {
                calls.incrementAndGet()
                return JSONObject().put("value", "局域网数据")
            }
        }
        fun result(method: String): JSONObject {
            val wire = JSONObject(AgentLanCrypto.reply(key, body(method), commands).toString(Charsets.UTF_8))
            return JSONObject(AgentLanCrypto.open(key, Base64.getDecoder().decode(wire.getString("payload")), "response").toString(Charsets.UTF_8))
        }
        assertEquals("局域网数据", result("query.fixture").getJSONObject("result").getString("value"))
        for (method in listOf("action.sms.send", "admin.services.start")) {
            assertEquals("query_only", result(method).getJSONObject("error").getString("code"))
        }
        assertEquals(1, calls.get())
        assertThrows(Exception::class.java) { AgentLanCrypto.reply(key, body("query.fixture", 1), commands) }
        assertEquals(1, calls.get())
    }
}
