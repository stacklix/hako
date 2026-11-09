using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal sealed record GitRepositorySummary(string Id, string Name, string? Branch, string? RemoteName, string? RemoteUrl,
    string? PushTarget, int ChangedCount, int? Ahead, int? Behind, bool CanCommit, bool CanPush, string? Error = null);
internal sealed record GitRepositoryPage(string Root, GitRepositorySummary[] Repositories, string? NextCursor, bool ScanIncomplete);
internal sealed record GitChange(string Path, string Status, int Index = 0);
internal sealed record GitPendingCommit(string Id, string Subject);
internal sealed record GitRepositoryDetail(GitRepositorySummary Repository, string Revision, GitChange[] Changes,
    GitPendingCommit[] Pending, bool ChangesTruncated, string? PullSource, string? PullUrl, bool CanPull, bool RemoteCheckFresh);
internal sealed record GitOperation(string Id, string State, string? Message = null);
internal enum GitOperationKind { Commit, Push, Fetch, Pull }

internal sealed class GitRepositoryMonitor
{
    private const int PageSize = 6;
    private static readonly TimeSpan RemoteCheckLifetime = TimeSpan.FromHours(1);
    private static readonly StringComparer PathOrder = StringComparer.OrdinalIgnoreCase;
    private readonly string root;
    private readonly TimeProvider timeProvider;
    private readonly SemaphoreSlim scanGate = new(1, 1);
    private readonly byte[] revisionKey = RandomNumberGenerator.GetBytes(32);
    private readonly Dictionary<string, GitOperation> jobs = new();
    private readonly Dictionary<string, DateTimeOffset> remoteChecks = new();
    private readonly Dictionary<string, Scan> scans = new();
    private string? runningJob;

    private sealed class Scan
    {
        public readonly List<string> Ids = new();
        public readonly Stack<string> Directories = new();
        public DateTimeOffset Accessed = DateTimeOffset.UtcNow;
        public bool Incomplete;
        public int Turn;
    }
    private sealed record Snapshot(GitRepositorySummary Summary, string Revision, GitChange[] Changes,
        string? Head, string? Remote, string? RemoteRef, string? ComparedRef, string? TrackingRef,
        string? RemoteTip, string? FetchUrl, bool CleanOperation, string? RemoteCheckKey)
    {
        public string? PullSource => FetchUrl is not null && TrackingRef is not null && RemoteRef is not null
            ? Remote + "/" + RemoteRef["refs/heads/".Length..] : null;
        public bool CanPull => PullSource is not null && RemoteTip is not null && CleanOperation &&
            Changes.Length == 0 && Summary.Ahead == 0 && Summary.Behind > 0;
    }

    public GitRepositoryMonitor(string? root = null, TimeProvider? timeProvider = null)
    {
        this.root = Path.GetFullPath(root ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Code"));
        this.timeProvider = timeProvider ?? TimeProvider.System;
    }

    public async Task<object?> ListAsync(JsonElement parameters, CancellationToken token)
    {
        CheckKeys(parameters, "cursor");
        var cursor = parameters.TryGetProperty("cursor", out _) ? ReadString(parameters, "cursor", 64) : null;
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
        budget.CancelAfter(TimeSpan.FromSeconds(9));
        try
        {
            await scanGate.WaitAsync(budget.Token);
            string session;
            int offset = 0, turn;
            string[] ids;
            bool incomplete, more;
            try
            {
                var now = DateTimeOffset.UtcNow;
                foreach (var expired in scans.Where(entry => now - entry.Value.Accessed > TimeSpan.FromMinutes(3)).Select(entry => entry.Key).ToArray())
                    scans.Remove(expired);
                Scan scan;
                if (cursor is null)
                {
                    if (scans.Count >= 8) scans.Remove(scans.MinBy(entry => entry.Value.Accessed).Key);
                    session = Guid.NewGuid().ToString("N");
                    scans.Add(session, scan = new Scan());
                    try
                    {
                        if (Directory.Exists(root))
                        {
                            if (IsReparse(root)) scan.Incomplete = true;
                            else
                                foreach (var directory in Directory.EnumerateDirectories(root).OrderDescending(PathOrder))
                                    if (!PathOrder.Equals(Path.GetFileName(directory), ".git")) scan.Directories.Push(directory);
                        }
                    }
                    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { scan.Incomplete = true; }
                }
                else
                {
                    var parts = cursor.Split(':');
                    if (parts is not [var key, var index, _] || !scans.TryGetValue(key, out scan!) ||
                        !int.TryParse(index, NumberStyles.None, CultureInfo.InvariantCulture, out offset) || offset > scan.Ids.Count)
                        throw Failure("git_scan_expired", "扫描记录已失效，请下拉重新扫描。");
                    session = key;
                }
                scan.Accessed = now;
                Discover(scan, offset, budget.Token);
                ids = scan.Ids.Skip(offset).Take(PageSize).ToArray();
                incomplete = scan.Incomplete;
                more = scan.Ids.Count > offset + ids.Length || scan.Directories.Count > 0;
                turn = ++scan.Turn;
            }
            finally { scanGate.Release(); }
            var rows = (await Task.WhenAll(ids.Select(async id =>
            {
                try { return (await ReadAsync(id, budget.Token, includePull: false)).Summary; }
                catch (AgentActionException e) when (e.Code != "git_unavailable")
                { return new GitRepositorySummary(id, RepoName(id), null, null, null, null, 0, null, null, false, false, e.Message); }
            }))).ToList();
            GitRepositoryPage Page() => new("~/Code", rows.ToArray(),
                more ? FormattableString.Invariant($"{session}:{offset + rows.Count}:{turn}") : null, incomplete);
            var page = Page();
            while (rows.Count > 1 && JsonSerializer.SerializeToUtf8Bytes(page, AgentConnection.Json).Length > 56 * 1024)
            {
                rows.RemoveAt(rows.Count - 1);
                more = true;
                page = Page();
            }
            return page;
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { throw Failure("git_timeout", "扫描仓库超时，请下拉重试。"); }
    }

    public async Task<object?> DetailAsync(JsonElement parameters, CancellationToken token)
    {
        CheckKeys(parameters, "repository");
        var id = ReadString(parameters, "repository", 1024);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
        budget.CancelAfter(TimeSpan.FromSeconds(9));
        try
        {
            var snapshot = await ReadAsync(id, budget.Token);
            var pending = Array.Empty<GitPendingCommit>();
            if (snapshot.Head is not null && snapshot.Summary.Ahead != 0 && snapshot.Summary.RemoteUrl is not null)
            {
                var range = snapshot.ComparedRef is null ? snapshot.Head : snapshot.ComparedRef + ".." + snapshot.Head;
                var result = await GitCommand.RunAsync(Resolve(id), budget.Token, ["log", "-n", "20", "--format=%H%x00%s", "--end-of-options", range, "--"]);
                if (result.ExitCode == 0)
                    pending = result.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).Select(line => line.TrimEnd('\r').Split('\0', 2))
                        .Where(parts => parts.Length == 2).Select(parts => new GitPendingCommit(parts[0], Clip(parts[1], 240))).ToArray();
            }
            var changes = snapshot.Changes.Where(change => change.Path.Length <= 1024).Take(100).ToList();
            // Keep the complete WebSocket response well below the 64 KiB frame limit.
            var detail = new GitRepositoryDetail(snapshot.Summary, snapshot.Revision, changes.ToArray(), pending,
                changes.Count != snapshot.Changes.Length, snapshot.PullSource, snapshot.FetchUrl, snapshot.CanPull,
                HasFreshRemoteCheck(snapshot.RemoteCheckKey));
            while (JsonSerializer.SerializeToUtf8Bytes(detail, AgentConnection.Json).Length > 56 * 1024)
            {
                changes.RemoveAt(changes.Count - 1);
                detail = detail with { Changes = changes.ToArray(), ChangesTruncated = true };
            }
            return detail;
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { throw Failure("git_timeout", "读取仓库超时，请下拉重试。"); }
    }

    public Task<object?> StartAsync(JsonElement parameters, GitOperationKind kind, CancellationToken token)
    {
        bool commit = kind == GitOperationKind.Commit;
        CheckKeys(parameters, kind switch
        {
            GitOperationKind.Commit => ["repository", "revision", "message", "files"],
            GitOperationKind.Fetch => ["repository"],
            _ => ["repository", "revision"]
        });
        var id = ReadString(parameters, "repository", 1024);
        var revision = kind == GitOperationKind.Fetch ? null : ReadString(parameters, "revision", 64);
        var message = commit ? ReadString(parameters, "message", 2000).Trim() : null;
        int[] files = [];
        if (commit)
        {
            if (string.IsNullOrWhiteSpace(message) || !parameters.TryGetProperty("files", out var values) ||
                values.ValueKind != JsonValueKind.Array || values.GetArrayLength() is < 1 or > 100)
                throw Invalid("请选择文件并填写提交说明。");
            files = values.EnumerateArray().Select(value => value.ValueKind == JsonValueKind.Number &&
                value.TryGetInt32(out var index) && index >= 0 ? index : throw Invalid("提交文件索引无效。")).ToArray();
            if (files.Distinct().Count() != files.Length) throw Invalid("提交文件列表包含重复项。");
        }
        token.ThrowIfCancellationRequested();
        lock (jobs)
        {
            if (runningJob is not null) throw Failure("git_busy", "设备正在处理 Git 操作，请等待完成后刷新。");
            var job = new GitOperation(Guid.NewGuid().ToString("N"), "running");
            if (jobs.Count >= 32) jobs.Remove(jobs.Keys.First());
            jobs.Add(job.Id, job);
            runningJob = job.Id;
            _ = Task.Run(() => ExecuteAsync(job, kind, id, revision, message, files));
            return Task.FromResult<object?>(job);
        }
    }

    public Task<object?> OperationAsync(JsonElement parameters, CancellationToken token)
    {
        CheckKeys(parameters, "operation");
        var id = ReadString(parameters, "operation", 32);
        token.ThrowIfCancellationRequested();
        lock (jobs)
            return Task.FromResult<object?>(jobs.TryGetValue(id, out var job) ? job :
                throw Failure("git_operation_missing", "操作结果已过期，请刷新仓库核对当前状态。"));
    }

    private async Task ExecuteAsync(GitOperation job, GitOperationKind kind, string id, string? revision, string? message, int[] files)
    {
        using var timeout = new CancellationTokenSource(TimeSpan.FromMinutes(2));
        var token = timeout.Token;
        GitOperation result;
        try
        {
            var snapshot = await ReadAsync(id, token);
            if (revision is not null && snapshot.Revision != revision)
                throw Failure("git_changed", "仓库状态已变化，请刷新并重新确认。");
            var directory = Resolve(id);
            switch (kind)
            {
                case GitOperationKind.Commit: await CommitAsync(directory, snapshot, message!, files, token); break;
                case GitOperationKind.Push: await PushAsync(directory, snapshot, token); break;
                case GitOperationKind.Fetch: await FetchAsync(directory, snapshot, token); break;
                case GitOperationKind.Pull: await PullAsync(directory, snapshot, token); break;
            }
            result = job with { State = "succeeded" };
        }
        catch (AgentActionException e) { result = job with { State = "failed", Message = e.Message }; }
        catch (OperationCanceledException)
        { result = job with { State = "unknown", Message = "操作超时，请刷新仓库核对结果。" }; }
        catch (Exception)
        { result = job with { State = "unknown", Message = "操作结果未能确认，请刷新仓库核对。" }; }
        lock (jobs)
        {
            jobs[job.Id] = result;
            runningJob = null;
        }
    }

    private static async Task CommitAsync(string directory, Snapshot snapshot, string message, int[] files, CancellationToken token)
    {
        if (!snapshot.Summary.CanCommit) throw Failure("git_commit_unavailable", "请先在电脑上处理冲突、合并、变基或分离的 HEAD。");
        if (files.Any(index => index >= snapshot.Changes.Length)) throw Invalid("所选文件已变化，请刷新仓库。");
        var selected = files.Select(index => snapshot.Changes[index]).ToArray();
        var untracked = selected.Where(change => change.Status == "??").Select(change => change.Path).ToArray();
        var pathspec = string.Join('\0', selected.Select(change => change.Path)) + '\0';
        bool committed = false;
        try
        {
            if (untracked.Length > 0)
            {
                var added = await GitCommand.RunAsync(directory, token,
                    ["add", "--intent-to-add", "--pathspec-from-file=-", "--pathspec-file-nul"], string.Join('\0', untracked) + '\0');
                if (added.ExitCode != 0) throw Failure("git_commit_failed", "Git 无法准备所选新增文件，请在电脑上检查仓库。");
            }
            var result = await GitCommand.RunAsync(directory, token,
                ["commit", "--only", "-m", message, "--pathspec-from-file=-", "--pathspec-file-nul"], pathspec);
            if (result.ExitCode != 0) throw Failure("git_commit_failed", "Git 未创建提交，请检查本机提交身份、签名和 Git 钩子。");
            committed = true;
        }
        finally
        {
            if (!committed && untracked.Length > 0)
            {
                // Undo only our intent-to-add entries, and only while HEAD is still unchanged.
                await RestoreIntentAsync(directory, snapshot.Head, untracked);
            }
        }
    }

    private static async Task RestoreIntentAsync(string directory, string? originalHead, string[] paths)
    {
        using var budget = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        var token = budget.Token;
        try
        {
            var head = await GitCommand.RunAsync(directory, token, ["rev-parse", "--verify", "HEAD"]);
            if ((head.ExitCode == 0 ? head.Output.Trim() : null) != originalHead) return;
            var state = await GitCommand.RunAsync(directory, token, StatusArgs);
            if (state.ExitCode != 0) return;
            var intent = ReadChanges(state.Output).Where(change => change.Status == ".A").Select(change => change.Path).ToHashSet(StringComparer.Ordinal);
            var cleanup = paths.Where(intent.Contains).ToArray();
            if (cleanup.Length == 0) return;
            await GitCommand.RunAsync(directory, token,
                ["reset", "--pathspec-from-file=-", "--pathspec-file-nul"], string.Join('\0', cleanup) + '\0');
        }
        catch (Exception) { /* The original error is reported and the UI reloads Git status. */ }
    }

    private static async Task PushAsync(string directory, Snapshot snapshot, CancellationToken token)
    {
        if (!snapshot.Summary.CanPush || snapshot.Head is null || snapshot.Remote is null || snapshot.RemoteRef is null)
            throw Failure("git_push_unavailable", "没有可推送的提交，或当前分支需要先在电脑上同步。");
        var result = await GitCommand.RunAsync(directory, token,
            ["push", "--porcelain", "--no-force", "--no-all", "--no-prune", "--no-mirror", "--no-tags", "--no-follow-tags", "--recurse-submodules=no",
                "--", snapshot.Remote, snapshot.Head + ":" + snapshot.RemoteRef]);
        if (result.ExitCode != 0)
            throw Failure("git_push_failed", "Git 未确认推送成功，请刷新核对远端状态，并在电脑上检查权限或分支差异。");
    }

    private async Task FetchAsync(string directory, Snapshot snapshot, CancellationToken token)
    {
        if (snapshot.RemoteCheckKey is not { } key || snapshot.Remote is null || snapshot.RemoteRef is null || snapshot.TrackingRef is null)
            throw Failure("git_fetch_unavailable", "当前分支没有可检查的远端分支。");
        if (HasFreshRemoteCheck(key)) return;
        var result = await GitCommand.RunAsync(directory, token,
            ["fetch", "--no-tags", "--no-prune", "--no-prune-tags", "--no-recurse-submodules", "--no-write-fetch-head",
                "--no-auto-maintenance", "--refmap=", "--", snapshot.Remote, "+" + snapshot.RemoteRef + ":" + snapshot.TrackingRef]);
        if (result.ExitCode != 0)
            throw Failure("git_fetch_failed", "无法检查远端分支，请核对电脑上的 Git 凭据、网络和分支配置。");
        RememberRemoteCheck(key);
    }

    private bool HasFreshRemoteCheck(string? key)
    {
        if (key is null) return false;
        var now = timeProvider.GetUtcNow();
        lock (jobs)
            return remoteChecks.TryGetValue(key, out var checkedAt) && IsFresh(checkedAt, now);
    }

    private void RememberRemoteCheck(string key)
    {
        var now = timeProvider.GetUtcNow();
        lock (jobs)
        {
            foreach (var expired in remoteChecks.Where(entry => !IsFresh(entry.Value, now)).Select(entry => entry.Key).ToArray())
                remoteChecks.Remove(expired);
            remoteChecks[key] = now;
        }
    }

    private static bool IsFresh(DateTimeOffset checkedAt, DateTimeOffset now) =>
        checkedAt <= now && now - checkedAt < RemoteCheckLifetime;

    private static async Task PullAsync(string directory, Snapshot snapshot, CancellationToken token)
    {
        if (!snapshot.CanPull || snapshot.RemoteTip is null)
            throw Failure("git_pull_unavailable", "当前分支无法快进，请先在电脑上处理本地改动或分叉。");
        var result = await GitCommand.RunAsync(directory, token,
            ["-c", "submodule.recurse=false", "merge", "--ff-only", "--no-autostash", "--no-overwrite-ignore", "--", snapshot.RemoteTip]);
        if (result.ExitCode != 0)
            throw Failure("git_pull_failed", "Git 未完成快进，请在电脑上检查工作区和分支状态。");
    }

    private static readonly string[] StatusArgs =
        ["status", "--porcelain=v2", "--branch", "--ahead-behind", "-z", "--untracked-files=all", "--ignored=no",
            "--no-renames", "--ignore-submodules=dirty"];

    private async Task<Snapshot> ReadAsync(string id, CancellationToken token, bool includePull = true)
    {
        var directory = Resolve(id);
        var top = await GitCommand.RunAsync(directory, token, ["rev-parse", "--show-toplevel"]);
        if (top.ExitCode != 0 || !PathOrder.Equals(Path.GetFullPath(top.Output.TrimEnd('\n', '\r')), directory))
            throw Failure("git_repository_missing", "此目录不是可访问的 Git 工作区。");
        var status = await GitCommand.RunAsync(directory, token, StatusArgs);
        if (status.ExitCode != 0) throw Failure("git_status_failed", "无法读取仓库状态，请在电脑上检查仓库。");
        var records = status.Output.Split('\0');
        string? Header(string key) => records.FirstOrDefault(value => value.StartsWith(key, StringComparison.Ordinal))?[key.Length..];
        var head = Header("# branch.oid ");
        if (head == "(initial)") head = null;
        var branch = Header("# branch.head ");
        if (branch == "(detached)") branch = null;
        var changes = ReadChanges(status.Output);
        var comparedRef = Header("# branch.upstream ");
        int? ahead = null, behind = null;
        var counts = Header("# branch.ab ")?.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (counts is { Length: 2 } && int.TryParse(counts[0], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var a)
            && int.TryParse(counts[1], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var b) && a >= 0 && b <= 0)
        { ahead = a; behind = -b; }

        string? remote = null, remoteRef = null, remoteUrl = null, trackingRef = null;
        if (branch is not null)
        {
            var tracked = await GitCommand.RunAsync(directory, token,
                ["for-each-ref", "--format=%(upstream:remotename)%00%(upstream:remoteref)%00%(upstream)", "refs/heads/" + branch]);
            var upstream = tracked.Output.TrimEnd('\n', '\r').Split('\0', 3);
            if (upstream is [var name, var reference, var upstreamRef] && name.Length > 0)
            {
                if (name != "." && reference.StartsWith("refs/heads/", StringComparison.Ordinal))
                {
                    remote = name; remoteRef = reference;
                    if (upstreamRef.StartsWith("refs/remotes/", StringComparison.Ordinal))
                    {
                        trackingRef = upstreamRef;
                        if (comparedRef is not null) comparedRef = upstreamRef;
                    }
                }
                else { ahead = null; behind = null; comparedRef = null; }
            }
            else if (comparedRef is null)
            {
                remote = "origin"; remoteRef = "refs/heads/" + branch;
                trackingRef = "refs/remotes/origin/" + branch;
            }
        }
        var displayRemote = remote ?? "origin";
        var urls = await GitCommand.RunAsync(directory, token, ["remote", "get-url", "--push", "--all", "--", displayRemote]);
        if (urls.ExitCode != 0)
        {
            var remotes = await GitCommand.RunAsync(directory, token, ["remote"]);
            displayRemote = remotes.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries).FirstOrDefault()?.TrimEnd('\r');
            if (!string.IsNullOrEmpty(displayRemote))
                urls = await GitCommand.RunAsync(directory, token, ["remote", "get-url", "--push", "--all", "--", displayRemote]);
        }
        var destinations = urls.ExitCode == 0 ? urls.Output.Split('\n', StringSplitOptions.RemoveEmptyEntries) : [];
        if (destinations.Length > 0) remoteUrl = SafeRemoteUrl(destinations[0].TrimEnd('\r'));
        var singleDestination = remote is not null && displayRemote == remote && destinations.Length == 1 && remoteUrl is not null;

        if (head is not null && trackingRef is not null && counts is null)
        {
            var comparison = await GitCommand.RunAsync(directory, token, ["rev-list", "--left-right", "--count", head + "..." + trackingRef, "--"]);
            var values = comparison.Output.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (comparison.ExitCode == 0 && values is [var left, var right] && int.TryParse(left, out var l) && int.TryParse(right, out var r))
            { ahead = l; behind = r; comparedRef = trackingRef; }
        }

        string? fetchUrl = null, rawFetchUrl = null, remoteTip = null;
        if (includePull && remote is not null && trackingRef is not null && head is not null)
        {
            var fetch = await GitCommand.RunAsync(directory, token, ["remote", "get-url", "--", remote]);
            if (fetch.ExitCode == 0)
            {
                rawFetchUrl = fetch.Output.TrimEnd('\n', '\r');
                fetchUrl = SafeRemoteUrl(rawFetchUrl);
            }
            if (fetchUrl is not null && behind > 0)
            {
                var tip = await GitCommand.RunAsync(directory, token, ["rev-parse", "--verify", "--end-of-options", trackingRef + "^{commit}"]);
                if (tip.ExitCode == 0) remoteTip = tip.Output.Trim();
            }
        }
        var cleanOperation = branch is not null && !changes.Any(change => change.Status.StartsWith('U')) &&
            !await HasInProgressOperationAsync(directory, token);
        var summary = new GitRepositorySummary(id, RepoName(id), branch, remoteUrl is null ? null : displayRemote,
            remoteUrl, singleDestination && remoteRef is not null ? remote + "/" + remoteRef["refs/heads/".Length..] : null,
            changes.Length, ahead, behind, cleanOperation && changes.Length > 0,
            cleanOperation && singleDestination && head is not null && remoteRef is not null && behind.GetValueOrDefault() == 0 && ahead != 0);
        var revision = HashSnapshot(new { id, status = status.Output, remote, remoteRef, urls = urls.Output, ahead, behind,
            cleanOperation, trackingRef, rawFetchUrl, remoteTip });
        var remoteCheckKey = fetchUrl is not null && trackingRef is not null && remoteRef is not null
            ? HashSnapshot(new { directory = directory.ToUpperInvariant(), remote, remoteRef, trackingRef, rawFetchUrl }) : null;
        return new(summary, revision, changes, head, remote, remoteRef, comparedRef, trackingRef, remoteTip, fetchUrl, cleanOperation, remoteCheckKey);
    }

    private string HashSnapshot<T>(T value) => Convert.ToHexString(
        HMACSHA256.HashData(revisionKey, JsonSerializer.SerializeToUtf8Bytes(value)));

    private static GitChange[] ReadChanges(string status) => status.Split('\0').Select(record =>
    {
        if (record.StartsWith("? ", StringComparison.Ordinal)) return new GitChange(record[2..], "??");
        var parts = record.StartsWith("1 ", StringComparison.Ordinal) ? record.Split(' ', 9) :
            record.StartsWith("u ", StringComparison.Ordinal) ? record.Split(' ', 11) : [];
        return parts.Length > 0 ? new GitChange(parts[^1], parts[0] == "u" ? "UU" : parts[1]) : null;
    }).OfType<GitChange>().Select((change, index) => change with { Index = index }).ToArray();

    private static async Task<bool> HasInProgressOperationAsync(string directory, CancellationToken token)
    {
        var metadata = await GitCommand.RunAsync(directory, token, ["rev-parse", "--absolute-git-dir"]);
        if (metadata.ExitCode != 0) return true;
        var gitDir = metadata.Output.TrimEnd('\n', '\r');
        return new[] { "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer" }
            .Select(name => Path.Combine(gitDir, name)).Any(path => File.Exists(path) || Directory.Exists(path));
    }

    private void Discover(Scan scan, int offset, CancellationToken token)
    {
        var clock = Stopwatch.StartNew();
        while (scan.Ids.Count <= offset + PageSize && clock.Elapsed < TimeSpan.FromMilliseconds(1500) &&
            scan.Directories.TryPop(out var directory))
        {
            token.ThrowIfCancellationRequested();
            try
            {
                if (IsReparse(directory)) { scan.Incomplete = true; continue; }
                if (HasGitMarker(directory)) scan.Ids.Add(Path.GetFileName(directory));
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { scan.Incomplete = true; }
        }
    }

    private string Resolve(string id)
    {
        var directory = root;
        try
        {
            if (IsReparse(directory)) throw Invalid("Code 目录不能指向其他位置。");
            foreach (var part in id == "." ? [] : id.Split('/'))
            {
                if (part.Length == 0 || part is "." or ".." || part.TrimEnd(' ', '.') != part ||
                    part.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 || part.Contains('\\') || PathOrder.Equals(part, ".git"))
                    throw Invalid("仓库标识无效。");
                directory = Path.Combine(directory, part);
                if (IsReparse(directory)) throw Invalid("仓库路径不能经过目录链接。");
            }
            if (!HasGitMarker(directory)) throw Failure("git_repository_missing", "仓库已移动或移除，请重新扫描。");
            return directory;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        { throw Failure("git_repository_missing", "无法访问此仓库，请重新扫描。"); }
    }

    private static bool IsReparse(string path) => (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
    private static bool HasGitMarker(string directory)
    {
        var marker = Path.Combine(directory, ".git");
        return (Directory.Exists(marker) || File.Exists(marker)) && !IsReparse(marker);
    }
    private string RepoName(string id) => id == "." ? Path.GetFileName(root) : id.Split('/')[^1];

    private static string? SafeRemoteUrl(string value)
    {
        if (value.Length is 0 or > 2048 || value.Any(char.IsControl)) return null;
        if (value.Contains("://", StringComparison.Ordinal))
        {
            if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)) return null;
            if (uri.IsFile) return uri.LocalPath;
            if (uri.Scheme is not ("http" or "https" or "ssh" or "git")) return null;
            return new UriBuilder(uri) { UserName = "", Password = "", Query = "", Fragment = "" }.Uri.AbsoluteUri;
        }
        // SCP-style Git addresses can contain a username, but no password or query.
        return value.Contains('?') || value.Contains('#') || value.Contains("::", StringComparison.Ordinal) ? null : value;
    }

    private static string Clip(string value, int max) => value.Length <= max ? value : value[..max];
    private static void CheckKeys(JsonElement parameters, params string[] keys)
    {
        var properties = parameters.EnumerateObject().Select(property => property.Name).ToArray();
        if (properties.Any(name => !keys.Contains(name, StringComparer.Ordinal)) ||
            properties.Distinct(StringComparer.Ordinal).Count() != properties.Length) throw Invalid("Git 命令参数无效。");
    }
    private static string ReadString(JsonElement parameters, string key, int max) =>
        parameters.TryGetProperty(key, out var value) ? CheckedString(value, max) : throw Invalid("缺少 Git 命令参数。");
    private static string CheckedString(JsonElement value, int max) =>
        value.ValueKind == JsonValueKind.String && value.GetString() is { Length: > 0 } text &&
        text.Length <= max && !text.Contains('\0') ? text : throw Invalid("Git 命令参数无效。");
    private static AgentActionException Invalid(string message) => Failure("invalid_params", message);
    private static AgentActionException Failure(string code, string message) => new(code, message);
}
