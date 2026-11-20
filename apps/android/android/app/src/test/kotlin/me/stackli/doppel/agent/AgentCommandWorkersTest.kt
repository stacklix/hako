package me.stackli.doppel.agent

import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.CountDownLatch
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class AgentCommandWorkersTest {
    @Test fun burstWaitsWithoutExceedingExecutionLimit() {
        val workers = agentCommandWorkers()
        val started = CountDownLatch(4)
        val release = CountDownLatch(1)
        val finished = CountDownLatch(16)
        val active = AtomicInteger()
        val peak = AtomicInteger()
        try {
            repeat(16) {
                workers.execute {
                    val running = active.incrementAndGet()
                    peak.accumulateAndGet(running, ::maxOf)
                    started.countDown()
                    try { release.await(5, TimeUnit.SECONDS) }
                    finally { active.decrementAndGet(); finished.countDown() }
                }
            }
            assertTrue(started.await(2, TimeUnit.SECONDS))
            assertEquals(12, workers.queue.size)
            release.countDown()
            assertTrue(finished.await(5, TimeUnit.SECONDS))
            assertEquals(4, peak.get())
        } finally { release.countDown(); workers.shutdownNow() }
    }

    @Test fun cancelledRequestsReleaseQueueSpaceAndNeverExecute() {
        val workers = agentCommandWorkers()
        val started = CountDownLatch(4)
        val release = CountDownLatch(1)
        val executed = AtomicInteger()
        try {
            repeat(4) { workers.execute { started.countDown(); release.await(5, TimeUnit.SECONDS) } }
            assertTrue(started.await(2, TimeUnit.SECONDS))
            val waiting = (1..16).map { workers.submit { executed.incrementAndGet() } }
            try { workers.execute { fail("Overloaded queue accepted another task") }; fail("Queue must remain bounded") }
            catch (_: RejectedExecutionException) { }
            waiting.forEach { it.cancel(true) }
            workers.purge()
            assertTrue(workers.queue.isEmpty())
            val next = workers.submit { executed.incrementAndGet() }
            release.countDown()
            next.get(5, TimeUnit.SECONDS)
            assertEquals(1, executed.get())
        } finally { release.countDown(); workers.shutdownNow() }
    }
}
