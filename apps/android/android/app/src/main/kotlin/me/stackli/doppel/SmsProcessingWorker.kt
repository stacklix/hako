package me.stackli.doppel

import android.content.Context
import androidx.work.Worker
import androidx.work.WorkerParameters

class SmsProcessingWorker(
    appContext: Context,
    params: WorkerParameters,
) : Worker(appContext, params) {
    override fun doWork(): Result {
        val sender = inputData.getString(SmsPipeline.INPUT_SENDER).orEmpty()
        val body = inputData.getString(SmsPipeline.INPUT_BODY).orEmpty()
        val subscriptionId = inputData.getInt(SmsPipeline.INPUT_SUBSCRIPTION_ID, -1)
        if (body.isBlank()) {
            SmsPipeline.appendDebugEvent(applicationContext, "后台任务失败：短信内容为空")
            return Result.failure()
        }

        return runCatching {
            SmsPipeline.processIncomingSms(applicationContext, sender, body, subscriptionId)
            Result.success()
        }.getOrElse {
            SmsPipeline.appendDebugEvent(
                applicationContext,
                "后台任务失败：${it.message.orEmpty()}",
            )
            Result.retry()
        }
    }
}
