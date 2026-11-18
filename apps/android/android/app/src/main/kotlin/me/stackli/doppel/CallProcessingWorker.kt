package me.stackli.doppel

import android.content.Context
import androidx.work.Worker
import androidx.work.WorkerParameters

class CallProcessingWorker(
    appContext: Context,
    params: WorkerParameters,
) : Worker(appContext, params) {
    override fun doWork(): Result {
        val caller = inputData.getString(SmsPipeline.INPUT_CALLER).orEmpty()
        val subscriptionId = inputData.getInt(SmsPipeline.INPUT_SUBSCRIPTION_ID, -1)

        return runCatching {
            SmsPipeline.processIncomingCall(applicationContext, caller, subscriptionId)
            Result.success()
        }.getOrElse {
            SmsPipeline.appendDebugEvent(
                applicationContext,
                "来电后台任务失败：${it.message.orEmpty()}",
            )
            Result.retry()
        }
    }
}
