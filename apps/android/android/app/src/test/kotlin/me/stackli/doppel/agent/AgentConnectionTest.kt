package me.stackli.doppel.agent

import okhttp3.OkHttpClient
import okhttp3.EventListener
import okhttp3.Call
import okhttp3.Protocol
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.security.KeyPairGenerator
import java.security.Signature
import java.security.spec.MGF1ParameterSpec
import java.security.spec.PSSParameterSpec
import java.util.Base64
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.io.IOException

class AgentConnectionTest {
    @Test fun authenticatesDispatchesAndKeepsHistoryOutOfTelemetry() {
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost")
            .addSubjectAlternativeName("127.0.0.1").addSubjectAlternativeName("::1").build()
        val serverCertificates = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientCertificates = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val server = MockWebServer()
        server.useHttps(serverCertificates.sslSocketFactory(), false)
        server.start()
        val origin = server.url("/").toString().removeSuffix("/")
        val key = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }.generateKeyPair()
        val fingerprint = AgentProtocol.keyId(key.public.encoded)
        val challenge = "hako-agent-auth/v4\n$origin\nowner\n$fingerprint\nnonce".toByteArray()
        val messages = LinkedBlockingQueue<JSONObject>()
        val states = LinkedBlockingQueue<String>()
        val calls = LinkedBlockingQueue<String>()
        lateinit var peer: WebSocket
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (request.path == "/api/v1/version") return MockResponse().setChunkedBody("""{"serverVersion":"0.8.4","minimumAgentVersion":"1.4.7"}""", 7)
                if (request.path != "/ws/agent") return MockResponse().setResponseCode(404)
                assertNull(request.getHeader("Origin"))
                return MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) { peer = webSocket }
                    override fun onMessage(webSocket: WebSocket, text: String) {
                        val message = JSONObject(text)
                        when (message.getString("type")) {
                            "hello" -> {
                                messages.add(message)
                                webSocket.send(JSONObject().put("type", "challenge").put("payload", Base64.getEncoder().encodeToString(challenge)).toString())
                            }
                            "authenticate" -> {
                                val verifier = Signature.getInstance("RSASSA-PSS")
                                verifier.setParameter(PSSParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA256, 32, 1))
                                verifier.initVerify(key.public)
                                verifier.update(challenge)
                                assertTrue(verifier.verify(Base64.getDecoder().decode(message.getString("signature"))))
                                webSocket.send("""{"type":"authenticated","agentId":"android-test"}""")
                            }
                            else -> messages.add(message)
                        }
                    }
                })
            }
        }
        val failures = LinkedBlockingQueue<String>()
        val client = OkHttpClient.Builder()
            .protocols(listOf(Protocol.HTTP_1_1))
            .eventListener(object : EventListener() {
                override fun callFailed(call: Call, ioe: IOException) { failures.add(ioe.toString()) }
            })
            .sslSocketFactory(clientCertificates.sslSocketFactory(), clientCertificates.trustManager).build()
        val connection = AgentConnection(AgentSettings(true, origin, "owner", false, false), fingerprint, { payload ->
            val signer = Signature.getInstance("RSASSA-PSS")
            signer.setParameter(PSSParameterSpec("SHA-256", "MGF1", MGF1ParameterSpec.SHA256, 32, 1))
            signer.initSign(key.private); signer.update(payload)
            Base64.getEncoder().encodeToString(signer.sign())
        }, object : AgentCommands {
            override fun invoke(method: String, version: Int, params: JSONObject): JSONObject {
                calls.add(method)
                return if (method == "query.all") AgentProtocol.aggregate { JSONObject().put("state", "ok") }
                    else JSONObject().put("state", "ok")
            }
        }, { state, _, _ -> states.add(state) }, client)
        try {
            connection.start()
            assertEquals("connecting", states.poll(10, TimeUnit.SECONDS))
            val next = states.poll(10, TimeUnit.SECONDS)
            assertEquals(failures.peek() ?: "Version request failed", "connecting", next)
            assertEquals("authenticating", states.poll(10, TimeUnit.SECONDS))
            assertEquals("authenticating", states.poll(10, TimeUnit.SECONDS))
            assertEquals("connected", states.poll(10, TimeUnit.SECONDS))
            assertEquals(4, messages.poll(5, TimeUnit.SECONDS)!!.getInt("version"))
            peer.send("""{"type":"ping"}""")
            assertEquals("pong", messages.poll(5, TimeUnit.SECONDS)!!.getString("type"))
            peer.send("""{"type":"request","id":"r1","method":"query.all","version":1,"params":{}}""")
            val response = messages.poll(5, TimeUnit.SECONDS)!!
            assertEquals("r1", response.getString("id"))
            assertFalse(response.getJSONObject("result").getJSONObject("data").has("query.sms.messages"))
            assertEquals("query.all", calls.poll(5, TimeUnit.SECONDS))
            peer.send("""{"type":"telemetry_start","id":"t1"}""")
            val methods = (1..7).map { messages.poll(5, TimeUnit.SECONDS)!!.getString("method") }.toSet()
            assertEquals(setOf("query.device.status", AgentStorage.COMMAND, AgentBattery.COMMAND, AgentWifi.COMMAND, AgentScreen.COMMAND, "query.network.lan", "query.telephony.sims"), methods)
            peer.send("""{"type":"telemetry_stop","id":"t1"}""")
        } finally { connection.close(); server.close() }
    }

    @Test fun websocketOpeningHandshakeTimesOutAndRetries() {
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost")
            .addSubjectAlternativeName("127.0.0.1").addSubjectAlternativeName("::1").build()
        val serverCertificates = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientCertificates = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val server = MockWebServer()
        server.useHttps(serverCertificates.sslSocketFactory(), false)
        server.start()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse = when (request.path) {
                "/api/v1/version" -> MockResponse().setBody("""{"serverVersion":"0.8.5"}""")
                else -> MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE)
            }
        }
        val states = LinkedBlockingQueue<Pair<String, String>>()
        val client = OkHttpClient.Builder().readTimeout(0, TimeUnit.SECONDS)
            .protocols(listOf(Protocol.HTTP_1_1))
            .sslSocketFactory(clientCertificates.sslSocketFactory(), clientCertificates.trustManager).build()
        val connection = AgentConnection(AgentSettings(true, server.url("/").toString().trimEnd('/'), "owner", false, false),
            "key", { error("Handshake must not reach signing") }, object : AgentCommands {
                override fun invoke(method: String, version: Int, params: JSONObject): JSONObject = error("No commands expected")
            }, { state, message, _ -> states.add(state to message) }, client, handshakeTimeoutSeconds = 1)
        try {
            connection.start()
            assertEquals("connecting", states.poll(5, TimeUnit.SECONDS)?.first)
            assertEquals("connecting", states.poll(5, TimeUnit.SECONDS)?.first)
            val timeout = states.poll(5, TimeUnit.SECONDS)!!
            assertEquals("retrying", timeout.first)
            assertTrue(timeout.second.contains("WebSocket 握手超时"))
            // A timed-out opening must schedule a new version check instead of
            // leaving the stale "connecting" status indefinitely.
            assertEquals("connecting", states.poll(6, TimeUnit.SECONDS)?.first)
        } finally { connection.close(); server.close() }
    }
}
