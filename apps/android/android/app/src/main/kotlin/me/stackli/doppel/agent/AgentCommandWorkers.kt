package me.stackli.doppel.agent

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

// A detail-page refresh is a burst of independent state queries. Keep execution
// bounded while allowing the relay's request window and one telemetry job to wait.
internal fun agentCommandWorkers(): ThreadPoolExecutor =
    ThreadPoolExecutor(4, 4, 30, TimeUnit.SECONDS, ArrayBlockingQueue(16)).apply {
        allowCoreThreadTimeOut(true)
    }
