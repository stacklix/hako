package me.stackli.doppel

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class RemoteHttpAgentSettingsTest {
    private val server = RemoteHttpServer(RuntimeEnvironment.getApplication(), RemoteControlConfig())

    // Exercise routing without opening a network listener or touching a real Keystore.
    private fun route(method: String, path: String, body: JSONObject = JSONObject(), session: Boolean = false): Pair<Int, JSONObject> {
        val requestType = Class.forName("me.stackli.doppel.HttpRequest")
        val constructor = requestType.declaredConstructors.single().apply { isAccessible = true }
        val headers = mutableMapOf("content-type" to "application/json")
        if (session) {
            @Suppress("UNCHECKED_CAST")
            val sessions = server.javaClass.getDeclaredField("sessions").apply { isAccessible = true }
                .get(server) as MutableMap<String, Long>
            sessions["test-session"] = System.currentTimeMillis() + 60_000
            headers["cookie"] = "doppel_session=test-session"
        }
        val request = constructor.newInstance(method, path, headers, body.toString(), "127.0.0.1")
        val response = server.javaClass.getDeclaredMethod("route", requestType).apply { isAccessible = true }
            .invoke(server, request)
        val status = response.javaClass.getDeclaredField("status").apply { isAccessible = true }.getInt(response)
        val text = response.javaClass.getDeclaredField("body").apply { isAccessible = true }.get(response) as String
        return status to JSONObject(text)
    }

    @Test fun agentEndpointsRequireAuthentication() {
        for ((method, path) in listOf("GET" to "/api/agent/settings", "POST" to "/api/agent/settings", "POST" to "/api/agent/key")) {
            val (status, body) = route(method, path)
            assertEquals(401, status)
            assertEquals("unauthorized", body.getString("error"))
            assertFalse(body.has("publicKey"))
        }
    }

    @Test fun authenticatedUpdatesUseNativeValidation() {
        val body = JSONObject().put("enabled", false).put("server", "http://example.com")
            .put("username", "test").put("allowSms", false).put("allowCalls", false)
        val (status, result) = route("POST", "/api/agent/settings", body, session = true)
        assertEquals(400, status)
        assertEquals("invalid_params", result.getString("error"))
        assertFalse(result.has("privateKey"))
    }

    @Test fun malformedSettingsAreRejectedInsteadOfSavingDefaults() {
        val (status, result) = route("POST", "/api/agent/settings", session = true)
        assertEquals(400, status)
        assertEquals("invalid_params", result.getString("error"))
    }
}
