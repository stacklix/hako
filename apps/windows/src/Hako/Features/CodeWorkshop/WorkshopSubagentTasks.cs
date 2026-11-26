using System;
using System.Collections.Generic;
using System.Linq;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;

namespace Hako.Platform;

internal sealed record WorkshopSubagentInstruction(string Id, string MessageId, string Kind, string Text,
    int Offset, bool Complete, int Position);

internal sealed partial class CodeWorkshop
{
    private sealed record SubagentTaskMessage(string Id, string Agent, string Kind, string Text);
    private sealed class SubagentTaskIndex
    {
        internal readonly List<SubagentTaskMessage> Messages = [];
        internal readonly Dictionary<string, long> Updates = new();
        internal Task? Worker;
        internal bool Complete;
        internal bool Failed;
        internal string? Failure;
        internal int Revision, LoadedRevision = -1;
        internal string? Cursor, Head;
        internal string? RolloutPath;
        internal long RolloutOffset;
        internal long ObservedLength;
        internal readonly Dictionary<string, (string Kind, string Text)> Calls = new();
        internal readonly Dictionary<string, (string Agent, string Kind)> Activities = new();
        internal readonly Dictionary<string, int> Order = new();
    }
    private readonly Dictionary<string, SubagentTaskIndex> subagentTasks = new();

    private SubagentTaskIndex EnsureSubagentTasks(string parent, IEnumerable<JsonElement> children)
    {
        lock (gate)
        {
            if (!subagentTasks.TryGetValue(parent, out var index))
            {
                if (subagentTasks.Count >= 8)
                {
                    var unused = subagentTasks.FirstOrDefault(p => p.Value.Worker?.IsCompleted != false);
                    if (unused.Key is not null) subagentTasks.Remove(unused.Key);
                    else throw new WorkshopException("query_busy", "任务说明正在读取，请稍后重试。");
                }
                subagentTasks[parent] = index = new();
            }
            foreach (var child in children)
            {
                var id = CodexJson.Text(child, "id");
                var time = CodexJson.Field(child, "updatedAt");
                var updated = time.ValueKind == JsonValueKind.Number && time.TryGetInt64(out var value) ? value : 0;
                if (!index.Updates.TryGetValue(id, out var previous) || previous != updated)
                { index.Updates[id] = updated; index.Revision++; }
            }
            var appended = false;
            if (index.Worker?.IsCompleted != false && index.RolloutPath is not null)
            {
                try { appended = new FileInfo(index.RolloutPath).Length != index.ObservedLength; }
                catch (IOException) { appended = true; }
            }
            if (index.Worker?.IsCompleted != false && (index.LoadedRevision != index.Revision || index.Failed || appended))
            {
                var revision = appended ? ++index.Revision : index.Revision;
                index.Failed = false;
                index.Worker = Task.Run(() => ReadSubagentTasksAsync(parent, index, revision), stopping.Token);
            }
            return index;
        }
    }

    private async Task ReadSubagentTasksAsync(string parent, SubagentTaskIndex index, int revision)
    {
        try
        {
            var thread = await ThreadAsync(parent, false, stopping.Token);
            await ReadSubagentTaskCallsAsync(parent, CodexJson.Text(thread, "path"), index, stopping.Token);
            bool initial;
            string? cursor, anchor;
            lock (gate) { initial = !index.Complete; cursor = initial ? index.Cursor : null; anchor = index.Head; }
            var visited = new HashSet<string>();
            var additions = new List<SubagentTaskMessage>();
            var newerOrder = new List<string>();
            string? newHead = null;
            while (true)
            {
                var page = await ReadAsync("thread/items/list", new { threadId = parent, limit = 64,
                    sortDirection = initial ? "asc" : "desc", cursor }, stopping.Token);
                var rows = CodexJson.Items(CodexJson.Field(page, "data")).ToArray();
                var reached = false;
                foreach (var row in rows)
                {
                    var item = CodexJson.Field(row, "item");
                    var id = CodexJson.Text(item, "id");
                    if (id.Length > 0 && CodexJson.Text(item, "type") is "collabAgentToolCall" or "subAgentActivity")
                    {
                        if (initial) { lock (gate) index.Order.TryAdd(id, index.Order.Count); }
                        else newerOrder.Add(id);
                    }
                    if (id.Length > 0)
                    {
                        if (initial) newHead = id;
                        else newHead ??= id;
                    }
                    if (!initial && id.Length > 0 && id == anchor) { reached = true; break; }
                    var messages = SubagentTaskMessages(parent, item).ToList();
                    if (CodexJson.Text(item, "type") == "subAgentActivity")
                    {
                        var child = CodexJson.Text(item, "agentThreadId");
                        var kind = CodexJson.Text(item, "kind");
                        if (id.Length > 0 && Guid.TryParse(child, out _) && kind is "started" or "interacted")
                        {
                            lock (gate) index.Activities[id] = (child, kind == "started" ? "task" : "followup");
                        }
                    }
                    if (initial) { lock (gate) MergeTaskMessages(index, messages); }
                    else additions.AddRange(messages);
                }
                var next = CodexJson.Text(page, "nextCursor");
                if (next.Length == 0 || reached)
                {
                    await ReadSubagentTaskCallsAsync(parent, CodexJson.Text(thread, "path"), index, stopping.Token);
                    lock (gate)
                    {
                        foreach (var id in newerOrder.AsEnumerable().Reverse()) index.Order.TryAdd(id, index.Order.Count);
                        if (!initial) MergeTaskMessages(index, additions.AsEnumerable().Reverse());
                        MergeTaskMessages(index, index.Activities.Select(activity =>
                            index.Calls.TryGetValue(activity.Key, out var call) && call.Kind == activity.Value.Kind
                                ? new SubagentTaskMessage(activity.Key, activity.Value.Agent, call.Kind, call.Text) : null).OfType<SubagentTaskMessage>());
                        index.Complete = true; index.Cursor = null;
                        index.Head = newHead ?? index.Head;
                        index.LoadedRevision = revision;
                    }
                    return;
                }
                if (!visited.Add(next)) throw new InvalidOperationException("Repeated task history cursor");
                cursor = next;
                if (initial) lock (gate) { index.Cursor = cursor; index.Head = newHead ?? index.Head; }
            }
        }
        catch (Exception error) when (error is not OutOfMemoryException)
        {
            lock (gate) { index.Failed = true; index.Failure = error.GetType().Name + ": " + error.Message; }
            queryLog.Write("subagent/tasks", 0, 0, stopping.IsCancellationRequested ? "cancelled" : "read_failed");
        }
    }

    // Native activity records carry the receiving thread ID and call ID. The
    // recorded function call carries the original plaintext assignment. Join
    // these identities, never infer a task from an inherited user message.
    private async Task ReadSubagentTaskCallsAsync(string parent, string path, SubagentTaskIndex index, CancellationToken token)
    {
        if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) path = @"\\" + path[8..];
        else if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) path = path[4..];
        if (path.Length == 0 || !(SafePath(path, Path.Combine(home, "sessions")) || SafePath(path, Path.Combine(home, "archived_sessions"))))
            throw new IOException("Task source is outside the Codex history directories");
        using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 65536, true);
        if (index.RolloutPath != path || file.Length < index.RolloutOffset)
        {
            file.Position = 0;
            using var header = new StreamReader(file, Encoding.UTF8, false, 4096, leaveOpen: true);
            var line = await header.ReadLineAsync(token) ?? throw new IOException("Missing thread metadata");
            using var metadata = JsonDocument.Parse(line);
            if (CodexJson.Text(metadata.RootElement, "type") != "session_meta"
                || CodexJson.Text(CodexJson.Field(metadata.RootElement, "payload"), "id") != parent)
                throw new IOException("Thread metadata identity mismatch");
            lock (gate) { index.Calls.Clear(); index.RolloutOffset = 0; index.RolloutPath = path; }
        }
        file.Position = index.RolloutOffset;
        var buffer = new byte[65536];
        using var record = new MemoryStream();
        bool? wanted = null;
        long consumed = index.RolloutOffset;
        while (true)
        {
            var count = await file.ReadAsync(buffer, token);
            if (count == 0) break;
            var begin = 0;
            while (begin < count)
            {
                var end = Array.IndexOf(buffer, (byte)'\n', begin, count - begin);
                var length = (end < 0 ? count : end) - begin;
                var retained = 0;
                if (wanted is null)
                {
                    retained = Math.Min(length, 4096 - (int)record.Length);
                    record.Write(buffer, begin, retained);
                    if (record.Length >= 4096 || end >= 0) wanted = IsRecordedFunctionCall(record.GetBuffer().AsSpan(0, (int)record.Length));
                }
                if (wanted == true && retained < length) record.Write(buffer, begin + retained, length - retained);
                consumed += length;
                if (end < 0) break;
                consumed++;
                if (wanted == true)
                {
                    using var json = JsonDocument.Parse(record.GetBuffer().AsMemory(0, (int)record.Length));
                    var call = CodexJson.Field(json.RootElement, "payload");
                    var name = CodexJson.Text(call, "name");
                    if (name is "spawn_agent" or "followup_task" or "send_message")
                    {
                        using var arguments = JsonDocument.Parse(CodexJson.Text(call, "arguments"));
                        var text = CodexJson.Text(arguments.RootElement, "message");
                        var id = CodexJson.Text(call, "call_id");
                        if (id.Length > 0 && !string.IsNullOrWhiteSpace(text))
                            lock (gate) index.Calls[id] = (name == "spawn_agent" ? "task" : "followup", text);
                    }
                }
                lock (gate) index.RolloutOffset = consumed;
                record.SetLength(0); record.Position = 0; wanted = null; begin = end + 1;
            }
        }
        lock (gate) index.ObservedLength = file.Position;
        // An incomplete trailing line is deliberately left unread for the next pass.
    }

    private static bool IsRecordedFunctionCall(ReadOnlySpan<byte> prefix)
    {
        var reader = new Utf8JsonReader(prefix, false, default);
        var outer = false; var typeDepth = -1;
        while (reader.Read())
        {
            if (reader.TokenType == JsonTokenType.PropertyName && reader.ValueTextEquals("type")) typeDepth = reader.CurrentDepth;
            else if (typeDepth >= 0)
            {
                if (typeDepth == 1) { outer = reader.ValueTextEquals("response_item"); if (!outer) return false; }
                if (typeDepth == 2) return outer && reader.ValueTextEquals("function_call");
                typeDepth = -1;
            }
        }
        return false;
    }

    private static IEnumerable<SubagentTaskMessage> SubagentTaskMessages(string parent, JsonElement item)
    {
        if (CodexJson.Text(item, "type") != "collabAgentToolCall" || CodexJson.Text(item, "senderThreadId") != parent
            || CodexJson.Text(item, "status") != "completed") yield break;
        var tool = CodexJson.Text(item, "tool");
        if (tool is not ("spawnAgent" or "followupTask" or "sendInput" or "sendMessage")) yield break;
        var text = CodexJson.Text(item, "prompt");
        var id = CodexJson.Text(item, "id");
        if (id.Length == 0 || string.IsNullOrWhiteSpace(text)) yield break;
        foreach (var receiver in CodexJson.Items(CodexJson.Field(item, "receiverThreadIds")))
            if (receiver.ValueKind == JsonValueKind.String && Guid.TryParse(receiver.GetString(), out var child))
                yield return new(id, child.ToString("D"), tool == "spawnAgent" ? "task" : "followup", text);
    }

    private static void MergeTaskMessages(SubagentTaskIndex index, IEnumerable<SubagentTaskMessage> messages)
    {
        foreach (var message in messages)
        {
            var position = index.Messages.FindIndex(m => m.Id == message.Id && m.Agent == message.Agent);
            if (position >= 0) index.Messages[position] = message;
            else index.Messages.Add(message);
        }
    }

    private (string Task, string State, string Version) SubagentTaskSummary(SubagentTaskIndex index, string agent)
    {
        lock (gate)
        {
            var messages = index.Messages.Where(m => m.Agent == agent).OrderBy(m => index.Order[m.Id]).ToArray();
            var text = messages.FirstOrDefault(m => m.Kind == "task")?.Text ?? "";
            return (CodexJson.Clip(text, 160), index.Failed ? "error" : !index.Complete || index.LoadedRevision != index.Revision
                ? "loading" : text.Length == 0 ? "missing" : "ready", messages.Length + ":" + messages.LastOrDefault()?.Id);
        }
    }

    public async Task<object?> SubagentTaskReadAsync(JsonElement parameters, CancellationToken token)
    {
        CodexJson.Keys(parameters, "threadId", "applicationId", "agentId", "cursor");
        var parent = await SubagentParentAsync(parameters, token);
        var id = CodexJson.Required(parameters, "agentId", 100);
        if (!Guid.TryParse(id, out _)) throw CodexJson.Invalid();
        var thread = await ThreadAsync(id, false, token);
        if (!IsDirectSubagent(thread, parent)) throw new WorkshopException("codex_subagent_invalid", "该子代理不属于当前会话。");
        var index = EnsureSubagentTasks(parent, [thread]);
        SubagentTaskMessage[] messages;
        lock (gate) messages = index.Messages.Where(m => m.Agent == id).OrderBy(m => index.Order[m.Id]).ToArray();
        var cursor = CodexJson.Text(parameters, "cursor");
        var messageIndex = 0; var offset = 0;
        if (cursor.Length > 0)
        {
            var split = cursor.LastIndexOf('@');
            if (split < 1 || !int.TryParse(cursor[(split + 1)..], out offset) || offset < 0)
                throw CodexJson.Invalid();
            messageIndex = Array.FindIndex(messages, m => m.Id == cursor[..split]);
            if (messageIndex < 0 || offset > messages[messageIndex].Text.Length) throw CodexJson.Invalid();
        }
        var entries = new List<WorkshopSubagentInstruction>(); var bytes = 0;
        while (messageIndex < messages.Length && entries.Count < 12)
        {
            var message = messages[messageIndex];
            var length = Math.Min(4096, message.Text.Length - offset);
            if (length > 0 && offset + length < message.Text.Length && char.IsHighSurrogate(message.Text[offset + length - 1])) length--;
            var complete = offset + length == message.Text.Length;
            var entry = new WorkshopSubagentInstruction(message.Id + "@" + offset, message.Id, message.Kind,
                message.Text.Substring(offset, length), offset, complete, messageIndex);
            var size = JsonSerializer.SerializeToUtf8Bytes(entry, WorkshopProtocol.Json).Length;
            if (entries.Count > 0 && bytes + size > 38 * 1024) break;
            entries.Add(entry); bytes += size; offset += length;
            if (complete) { messageIndex++; offset = 0; }
        }
        return new { state = SubagentTaskSummary(index, id).State, entries,
            nextCursor = messageIndex < messages.Length ? messages[messageIndex].Id + "@" + offset : null };
    }
}
