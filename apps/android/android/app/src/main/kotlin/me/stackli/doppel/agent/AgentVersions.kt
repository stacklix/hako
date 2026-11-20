package me.stackli.doppel.agent

import me.stackli.doppel.BuildConfig
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.concurrent.TimeUnit

internal data class AndroidAgentRelease(val version: String, val buildId: Long)

// Administration stays in the guardian even when the business process is unavailable.
internal class AgentGuardianCommands(
    private val local: AgentCommands,
    private val versions: AgentVersions = AgentVersions(),
) : AgentCommands {
    override fun invoke(method: String, version: Int, params: JSONObject): JSONObject {
        if (!method.startsWith("admin.")) return local.invoke(method, version, params)
        if (method != AgentVersions.COMMAND) throw AgentError("unknown_method", "Android 守护进程未提供此管理命令")
        if (version != 1) throw AgentError("unsupported_version", "不支持此命令版本")
        AgentProtocol.fields(params, emptySet())
        return versions.read()
    }
}

internal class AgentVersions(
    private val currentVersion: String = BuildConfig.VERSION_NAME,
    private val currentBuild: String = "${BuildConfig.VERSION_NAME}+${BuildConfig.VERSION_CODE}",
    private val lookup: () -> AndroidAgentRelease? = { GitHubAndroidReleases.latest() },
    private val clock: () -> Instant = Instant::now,
) {
    private var snapshot: String? = null
    private var expires = Instant.MIN

    @Synchronized fun read(): JSONObject {
        if (clock() < expires) snapshot?.let { return JSONObject(it) }
        var state = "available"
        val latest = try { lookup().also { if (it == null) state = "no_release" } }
        catch (_: Exception) { state = "unavailable"; null }
        val checkedAt = clock()
        val result = JSONObject().put("currentVersion", currentVersion).put("currentBuild", currentBuild)
            .put("minimumServerVersion", AgentProtocol.MINIMUM_SERVER)
            .put("latestVersion", latest?.version ?: JSONObject.NULL)
            .put("latestBuildId", latest?.buildId ?: JSONObject.NULL)
            .put("latestCheckedAt", checkedAt.toString()).put("latestCheckState", state)
        snapshot = result.toString()
        expires = checkedAt.plusSeconds(if (state == "unavailable") 30 else 300)
        return result
    }

    companion object { const val COMMAND = "admin.agent.versions" }
}

internal object GitHubAndroidReleases {
    private val client = OkHttpClient.Builder().connectTimeout(5, TimeUnit.SECONDS)
        .readTimeout(8, TimeUnit.SECONDS).callTimeout(8, TimeUnit.SECONDS)
        .followRedirects(false).followSslRedirects(false).build()

    fun latest(): AndroidAgentRelease? {
        val request = Request.Builder().url("https://api.github.com/repos/stacklix/hako/releases?per_page=30")
            .header("User-Agent", "Nami-Agent/1.0").header("Accept", "application/vnd.github+json").build()
        client.newCall(request).execute().use { response ->
            check(response.isSuccessful)
            val source = checkNotNull(response.body).source()
            source.request(2 * 1024 * 1024L + 1)
            check(source.buffer.size <= 2 * 1024 * 1024)
            return parse(JSONArray(source.readUtf8()))
        }
    }

    fun parse(releases: JSONArray): AndroidAgentRelease? {
        val candidates = mutableListOf<AndroidAgentRelease>()
        for (index in 0 until releases.length()) {
            val release = releases.getJSONObject(index)
            if (release.getBoolean("draft") || release.getBoolean("prerelease")) continue
            val tag = release.getString("tag_name")
            val match = Regex("android-agent-((?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*)\\.(?:0|[1-9][0-9]*))-([1-9][0-9]*)").matchEntire(tag) ?: continue
            val version = match.groupValues[1]
            if (version.split('.').any { it.toIntOrNull() == null }) continue
            val build = match.groupValues[2].toLongOrNull() ?: continue
            val assets = release.getJSONArray("assets")
            val expected = "https://github.com/stacklix/hako/releases/download/$tag/Nami.apk"
            if ((0 until assets.length()).none {
                val asset = assets.getJSONObject(it)
                asset.optString("name") == "Nami.apk" && asset.optString("browser_download_url") == expected
            }) continue
            candidates.add(AndroidAgentRelease(version, build))
        }
        return candidates.maxWithOrNull(compareBy<AndroidAgentRelease>(
            { it.version.split('.')[0].toInt() }, { it.version.split('.')[1].toInt() },
            { it.version.split('.')[2].toInt() }, { it.buildId }))
    }
}
