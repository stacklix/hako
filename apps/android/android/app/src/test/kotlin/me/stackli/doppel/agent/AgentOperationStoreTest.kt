package me.stackli.doppel.agent

import android.content.Context
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config
import org.json.JSONObject
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
class AgentOperationStoreTest {
    private lateinit var context: Context

    @Before fun prepare() {
        context = RuntimeEnvironment.getApplication()
        context.deleteDatabase("hako-operations.db")
    }

    @Test fun executionIntentSurvivesReopeningAndRejectsDifferentParameters() {
        AgentOperationStore(context).use { store ->
            assertNull(store.begin("request", "fingerprint", "sms"))
        }
        AgentOperationStore(context).use { store ->
            val existing = store.begin("request", "fingerprint", "sms")!!
            assertEquals("submitting", existing.getString("status"))
            assertThrows(AgentError::class.java) { store.begin("request", "different-fingerprint", "sms") }
        }
    }

    @Test fun multipartSuccessRequiresEveryUniqueReceipt() {
        AgentOperationStore(context).use { store ->
            store.begin("request", "fingerprint", "sms")
            store.setParts("request", 2)
            store.update("request", "submitted", "waiting")
            store.receipt("request", 0, true)
            store.receipt("request", 0, true)
            assertEquals("submitted", store.get("request")!!.getString("status"))
            store.receipt("request", 1, true)
            assertEquals("sent", store.get("request")!!.getString("status"))
        }
    }

    @Test fun failureIsNotOverwrittenBySuccessfulPartsOrLateSubmit() {
        AgentOperationStore(context).use { store ->
            store.begin("request", "fingerprint", "sms")
            store.setParts("request", 2)
            store.receipt("request", 0, false)
            store.update("request", "submitted", "waiting", onlySubmitting = true)
            store.receipt("request", 1, true)
            assertEquals("failed", store.get("request")!!.getString("status"))
            assertEquals("failed", store.begin("request", "fingerprint", "sms")!!.getString("status"))
        }
    }

    @Test fun settingsFilesSupportConcurrentReadersAndAtomicWriters() {
        val pool = Executors.newFixedThreadPool(4)
        try {
            AgentSettingsStore.writeFile(context, "test-settings.json", JSONObject().put("counter", 0))
            val tasks = (1..20).map { value ->
                pool.submit {
                    AgentSettingsStore.writeFile(context, "test-settings.json", JSONObject().put("counter", value))
                    assertTrue(AgentSettingsStore.readFile(context, "test-settings.json").getInt("counter") in 1..20)
                }
            }
            tasks.forEach { it.get(10, TimeUnit.SECONDS) }
        } finally { pool.shutdownNow() }
    }
}
