package me.stackli.doppel.agent

import android.content.Context
import android.os.StatFs
import org.json.JSONObject
import java.time.Instant

internal object AgentStorage {
    const val COMMAND = "query.device.storage"

    fun snapshot(context: Context): JSONObject {
        try {
            // The app's private data lives on the internal user-data volume.
            // Do not sum emulated/shared storage: it may be the same filesystem.
            val stat = StatFs(context.filesDir.absolutePath)
            val total = stat.totalBytes
            val available = stat.availableBytes
            if (total <= 0 || available < 0 || available > total) throw IllegalStateException()
            return JSONObject().put("storageTotalBytes", total).put("storageAvailableBytes", available)
                .put("sampledAt", Instant.now().toString())
        } catch (_: Exception) {
            throw AgentError("storage_unavailable", "暂时无法读取内部存储空间")
        }
    }
}
