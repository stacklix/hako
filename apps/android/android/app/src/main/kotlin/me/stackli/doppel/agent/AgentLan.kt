package me.stackli.doppel.agent

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.ServerSocket
import java.net.Socket
import java.security.SecureRandom
import java.util.Base64
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.concurrent.thread

internal object AgentLanCrypto {
    private val random = SecureRandom()
    fun seal(key: ByteArray, plain: ByteArray, direction: String): ByteArray {
        val nonce = ByteArray(12).also(random::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD("hako-agent-lan-v1:$direction".toByteArray(Charsets.UTF_8))
        return nonce + cipher.doFinal(plain)
    }
    fun open(key: ByteArray, combined: ByteArray, direction: String): ByteArray {
        require(combined.size in 28..65564)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, combined.copyOfRange(0, 12)))
        cipher.updateAAD("hako-agent-lan-v1:$direction".toByteArray(Charsets.UTF_8))
        return cipher.doFinal(combined.copyOfRange(12, combined.size))
    }
    fun reply(key: ByteArray, body: ByteArray, commands: AgentCommands): ByteArray {
        val wire = JSONObject(body.toString(Charsets.UTF_8))
        require(wire.getInt("version") == 1)
        val request = JSONObject(open(key, Base64.getDecoder().decode(wire.getString("payload")), "request").toString(Charsets.UTF_8))
        val id = request.getString("id")
        UUID.fromString(id)
        require(kotlin.math.abs(System.currentTimeMillis().toDouble() - request.getLong("timestamp")) <= 30000)
        val reply = JSONObject().put("id", id)
        try {
            val method = request.getString("method")
            if (!method.startsWith("query.")) throw AgentError("query_only", "局域网数据通道只支持 query 命令")
            reply.put("result", commands.invoke(method, request.getInt("version"), request.getJSONObject("params")))
        } catch (error: AgentError) {
            reply.put("error", AgentProtocol.error(error))
        } catch (_: Exception) {
            reply.put("error", AgentProtocol.error(AgentError("query_failed", "局域网数据查询失败")))
        }
        var plain = reply.toString().toByteArray(Charsets.UTF_8)
        if (plain.size > 65536) plain = JSONObject().put("id", id)
            .put("error", AgentProtocol.error(AgentError("result_too_large", "查询结果超过大小限制")))
            .toString().toByteArray(Charsets.UTF_8)
        return JSONObject().put("version", 1).put("payload", Base64.getEncoder().encodeToString(seal(key, plain, "response")))
            .toString().toByteArray(Charsets.UTF_8)
    }
}

internal object AgentLanState {
    const val COMMAND = "query.network.lan"
    const val FILE = "hako-agent-lan.json"
    fun privateIPv4(address: InetAddress): Boolean {
        if (address !is Inet4Address) return false
        val b = address.address.map { it.toInt() and 255 }
        return b[0] == 10 || b[0] == 172 && b[1] in 16..31 || b[0] == 192 && b[1] == 168
    }
    private fun interfaces() = NetworkInterface.getNetworkInterfaces().toList().filter { it.isUp && !it.isLoopback }
    fun snapshot(context: Context): JSONObject {
        val state = AgentSettingsStore.readFile(context, FILE)
        val enabled = AgentSettingsStore(context).read().enabled && state.optInt("port") > 0
        val addresses = interfaces().flatMap { it.inetAddresses.toList() }.filter(::privateIPv4)
            .map { it.hostAddress }.distinct().sortedBy { it }
        return JSONObject().put("enabled", enabled).put("protocol", "hako-agent-lan-v1")
            .put("addresses", JSONArray(addresses)).put("port", if (enabled) state.getInt("port") else 0)
            .put("token", if (enabled) state.optString("token") else JSONObject.NULL)
    }
    fun localPeer(peer: InetAddress): Boolean {
        if (peer.isLoopbackAddress) return true
        if (!privateIPv4(peer)) return false
        val bytes = peer.address
        return interfaces().flatMap { it.interfaceAddresses }.any { local ->
            if (local.address !is Inet4Address || local.networkPrefixLength !in 1..32) return@any false
            val own = local.address.address
            bytes.indices.all { index ->
                val bits = (local.networkPrefixLength - index * 8).coerceIn(0, 8)
                val mask = (255 shl (8 - bits)) and 255
                (bytes[index].toInt() and mask) == (own[index].toInt() and mask)
            }
        }
    }
}

// Lives in :agent. Every query is forwarded through the private Binder to the main process.
internal class AgentLanServer(private val context: Context, private val commands: AgentCommands) : AutoCloseable {
    private val key = ByteArray(32).also(SecureRandom()::nextBytes)
    private val socket = ServerSocket(0, 8)
    private val clients = ConcurrentHashMap.newKeySet<Socket>()
    private val workers = ThreadPoolExecutor(4, 4, 0, TimeUnit.SECONDS, ArrayBlockingQueue(8))
    @Volatile private var closed = false
    init {
        try {
            AgentSettingsStore.writeFile(context, AgentLanState.FILE, JSONObject().put("port", socket.localPort)
                .put("token", Base64.getEncoder().encodeToString(key)))
            thread(name = "NamiAgentLan", isDaemon = true) {
                while (!closed) {
                    val client = try { socket.accept() } catch (_: Exception) { break }
                    clients.add(client)
                    try { workers.execute { try { serve(client) } finally { clients.remove(client); client.close() } } }
                    catch (_: Exception) { clients.remove(client); client.close() }
                }
            }
        } catch (error: Exception) { socket.close(); workers.shutdownNow(); throw error }
    }
    private fun serve(client: Socket) {
        try {
            if (!AgentLanState.localPeer(client.inetAddress)) return
            client.soTimeout = 10000
            val input = client.getInputStream().buffered()
            val header = java.io.ByteArrayOutputStream()
            while (header.size() < 8192) {
                val next = input.read()
                if (next < 0) return
                header.write(next)
                val data = header.toByteArray()
                if (data.size >= 4 && data.takeLast(4) == listOf<Byte>(13, 10, 13, 10)) break
            }
            val text = header.toString("US-ASCII")
            require(text.endsWith("\r\n\r\n"))
            val lines = text.split("\r\n")
            require(lines.first() == "POST /agent/v1/query HTTP/1.1")
            val headers = mutableMapOf<String, String>()
            for (line in lines.drop(1).filter { it.isNotEmpty() }) {
                val colon = line.indexOf(':')
                require(colon > 0)
                val name = line.substring(0, colon).trim().lowercase(java.util.Locale.ROOT)
                require(headers.put(name, line.substring(colon + 1).trim()) == null)
            }
            require("host" in headers && "origin" !in headers && "transfer-encoding" !in headers)
            val size = headers["content-length"]?.toInt() ?: return
            require(size in 1..96 * 1024)
            val body = ByteArray(size)
            var count = 0
            while (count < size) {
                val read = input.read(body, count, size - count)
                if (read < 0) return
                count += read
            }
            val result = AgentLanCrypto.reply(key, body, commands)
            val response = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ${result.size}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
            client.getOutputStream().apply { write(response.toByteArray(Charsets.US_ASCII)); write(result); flush() }
        } catch (_: Exception) { /* Invalid or unauthenticated requests expose no device information. */ }
    }
    override fun close() {
        closed = true
        socket.close()
        clients.forEach { runCatching { it.close() } }
        workers.shutdownNow()
        runCatching { AgentSettingsStore.writeFile(context, AgentLanState.FILE, JSONObject()) }
    }
}
