using System;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

internal sealed record WorkshopInputPrediction(string SourceTurnId, string Text);

internal sealed partial class CodeWorkshop
{
    // thread/sample samples the loaded context without adding a user turn. Do
    // not use turn/start: a suggestion must never become an actionable message.
    private const string PredictionPrompt = "Predict the user's most likely next message based on this conversation. " +
        "Return only one short message in the user's language, at most 100 characters, without quotes, explanation, or formatting. " +
        "Do not answer or perform the suggested task. If no useful next message is apparent, return an empty string.";

    // Called under gate, after the real turn has finished and its worker has
    // been retained. Sampling never delays completion or reserves a worker.
    private void StartPrediction(WorkshopJob job, CodexAppServer server)
    {
        if (job.State != "completed" || job.IsCompaction || job.ThreadId is null || job.TurnId is null ||
            job.ParentThreadId is not null || SidechatRoot(job.ThreadId) is not null ||
            jobs.Values.Any(value => value.Id != job.Id && value.ThreadId == job.ThreadId &&
                (value.Active || value.State == "queued"))) return;
        var cancel = CancellationTokenSource.CreateLinkedTokenSource(stopping.Token);
        cancel.CancelAfter(TimeSpan.FromSeconds(20));
        job.PredictionStop = cancel;
        job.PredictionPending = true;
        job.PredictionWork = Task.Run(async () =>
        {
            WorkshopInputPrediction? prediction = null;
            try
            {
                var result = await server.RequestAsync("thread/sample", new {
                    threadId = job.ThreadId, expectedTurnId = job.TurnId, prompt = PredictionPrompt,
                    disableMcp = true, turnTrigger = "composer_prediction"
                }, cancel.Token);
                prediction = ReadPrediction(result, job.TurnId);
            }
            catch (Exception error) when (error is not OutOfMemoryException)
            { queryLog.Write("thread/sample", 0, 0, error.GetType().Name); }
            finally
            {
                lock (gate)
                {
                    if (job.PredictionStop == cancel)
                    {
                        job.PredictionStop = null;
                        job.PredictionPending = false;
                        if (!cancel.IsCancellationRequested && job.State == "completed" &&
                            CurrentJob(RootJob(job)).Id == job.Id) job.Prediction = prediction;
                        Persist(job);
                    }
                }
                cancel.Dispose();
            }
        });
    }

    internal static WorkshopInputPrediction? ReadPrediction(JsonElement result, string sourceTurnId)
    {
        var text = CodexJson.Text(result, "text").Trim();
        return CodexJson.Text(result, "sourceTurnId") == sourceTurnId && text.Length is > 0 and <= 200 &&
            !text.Contains('\n') && !text.Contains('\r') ? new(sourceTurnId, text) : null;
    }

    private void CancelPredictions(string? threadId)
    {
        if (threadId is null) return;
        lock (gate)
        {
            foreach (var job in jobs.Values.Where(value => value.ThreadId == threadId))
            {
                job.PredictionStop?.Cancel();
                job.Prediction = null;
                job.PredictionPending = false;
            }
        }
    }
}
