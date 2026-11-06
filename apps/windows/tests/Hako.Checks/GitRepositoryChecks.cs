using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;
using Hako.Platform;

internal static class GitRepositoryChecks
{
    private static readonly CancellationToken Token = CancellationToken.None;

    public static async Task RunAsync()
    {
        var temporary = Directory.CreateTempSubdirectory("hako-git-checks-");
        try
        {
            var code = Directory.CreateDirectory(Path.Combine(temporary.FullName, "Code")).FullName;
            var repo = Directory.CreateDirectory(Path.Combine(code, "app")).FullName;
            var nested = Directory.CreateDirectory(Path.Combine(code, "team", "nested")).FullName;
            var bare = Path.Combine(temporary.FullName, "remote.git");
            await Git(temporary.FullName, "init", "--bare", "-b", "master", bare);
            await Git(code, "init", "-b", "master");
            await Git(nested, "init", "-b", "master");
            await Git(repo, "init", "-b", "master");
            await Git(repo, "config", "user.name", "Hako Test");
            await Git(repo, "config", "user.email", "hako@example.invalid");
            await Git(repo, "config", "commit.gpgSign", "false");
            await Git(repo, "remote", "add", "origin", bare);
            var excludesFile = Path.Combine(temporary.FullName, "global-excludes");
            File.WriteAllText(excludesFile, "global.tmp\n");
            await Git(repo, "config", "core.excludesFile", excludesFile);
            File.AppendAllText(Path.Combine(repo, ".git", "info", "exclude"), "\nlocal.tmp\n");
            File.WriteAllText(Path.Combine(repo, ".gitignore"), "ignored/\n");
            Directory.CreateDirectory(Path.Combine(repo, "ignored"));
            File.WriteAllText(Path.Combine(repo, "ignored", "nested.tmp"), "ignored by repository");
            File.WriteAllText(Path.Combine(repo, "local.tmp"), "ignored by repository-local settings");
            File.WriteAllText(Path.Combine(repo, "global.tmp"), "ignored by global settings");
            var clock = new TestClock();
            var monitor = new GitRepositoryMonitor(code, clock);
            const string id = "app";
            var page = (GitRepositoryPage)(await monitor.ListAsync(Json(new { }), Token))!;
            Require(page.Repositories.Single().Id == id, "only direct child repositories are discovered");
            try
            {
                await monitor.DetailAsync(Json(new { repository = "../remote.git" }), Token);
                throw new Exception("Git accepted a repository outside Code");
            }
            catch (AgentActionException error) when (error.Code == "invalid_params") { }

            File.WriteAllText(Path.Combine(repo, "base.txt"), "base");
            var initial = await Detail(monitor, id);
            Require(initial.Repository.ChangedCount == 2 &&
                initial.Changes.Select(change => change.Path).Order(StringComparer.Ordinal).SequenceEqual(new[] { ".gitignore", "base.txt" }),
                "ignored files are absent from counts and selectable changes");
            Require(initial.Repository.CanCommit && !initial.Repository.CanPush, "unborn branch can create a first commit");
            Require((await Run(monitor, GitOperationKind.Commit, new { repository = id, revision = initial.Revision, message = "Initial", files = initial.Changes.Select(change => change.Index).ToArray() })).State == "succeeded",
                "first commit with an untracked file");
            var first = await Detail(monitor, id);
            Require(first.Repository.Ahead is null && first.Repository.PushTarget == "origin/master" && first.Repository.CanPush,
                "first push uses origin and the current branch");
            Require((await Run(monitor, GitOperationKind.Push, new { repository = id, revision = first.Revision })).State == "succeeded", "first push");
            Require((await Detail(monitor, id)).Repository.Ahead == 0, "first push updates the local remote-tracking ref");
            await Git(repo, "branch", "--set-upstream-to=origin/master", "master");
            await Git(repo, "config", "status.aheadBehind", "false");
            var synced = await Detail(monitor, id);
            Require(synced.Repository.Ahead == 0 && synced.Repository.Behind == 0, "synced branch");
            File.WriteAllText(Path.Combine(repo, "base.txt"), "unrelated staged edit");
            await Git(repo, "add", "base.txt");
            File.WriteAllText(Path.Combine(repo, "new file.txt"), "selected");
            var dirty = await Detail(monitor, id);
            Require(dirty.Repository.ChangedCount == 2 && dirty.Repository.CanCommit, "staged and untracked status");
            var files = new[] { dirty.Changes.Single(change => change.Path == "new file.txt").Index };

            await Git(repo, "config", "user.name", "");
            var failure = await Run(monitor, GitOperationKind.Commit,
                new { repository = id, revision = dirty.Revision, message = "Fails", files });
            Require(failure.State == "failed", "failed commit reported");
            Require((await Detail(monitor, id)).Changes.Single(change => change.Path == "new file.txt").Status == "??",
                "failed commit restores temporary intent-to-add");
            await Git(repo, "config", "user.name", "Hako Test");

            var parameters = new { repository = id, revision = dirty.Revision, message = "Selected change", files };
            Require((await Run(monitor, GitOperationKind.Commit, parameters)).State == "succeeded", "selected file commit");
            Require((await Git(repo, "diff", "--cached", "--name-only")).Trim() == "base.txt", "unrelated staged change preserved");
            Require((await Git(repo, "show", "--format=", "--name-only", "HEAD")).Trim() == "new file.txt", "only the selected file committed");
            Require((await Run(monitor, GitOperationKind.Commit, parameters)).State == "failed", "old confirmation cannot repeat a commit");

            var ahead = await Detail(monitor, id);
            Require(ahead.Repository.Ahead == 1 && ahead.Repository.ChangedCount == 1 && ahead.Repository.CanPush &&
                ahead.Pending.Single().Subject == "Selected change", "dirty and ahead shown together");
            Require((await Run(monitor, GitOperationKind.Push, new { repository = id, revision = ahead.Revision })).State == "succeeded", "push to tracked remote");
            var pushed = await Detail(monitor, id);
            Require(pushed.Repository.Ahead == 0 && pushed.Repository.ChangedCount == 1, "push preserves the remaining change");
            Require((await Git(repo, "rev-parse", "HEAD")).Trim() == (await Git(bare, "rev-parse", "refs/heads/master")).Trim(),
                "remote branch contains the confirmed commit");

            var peer = Path.Combine(temporary.FullName, "peer");
            await Git(temporary.FullName, "clone", "--", bare, peer);
            await Git(peer, "config", "user.name", "Hako Test");
            await Git(peer, "config", "user.email", "hako@example.invalid");
            await Git(peer, "config", "commit.gpgSign", "false");
            File.WriteAllText(Path.Combine(peer, "remote.txt"), "remote update");
            Directory.CreateDirectory(Path.Combine(peer, "ignored"));
            File.WriteAllText(Path.Combine(peer, "ignored", "conflict.txt"), "remote version");
            await Git(peer, "add", "-f", "ignored/conflict.txt");
            await Git(peer, "add", "remote.txt");
            await Git(peer, "commit", "-m", "Remote update");
            await Git(peer, "push", "origin", "master");
            var originalHead = (await Git(repo, "rev-parse", "HEAD")).Trim();
            Require((await Run(monitor, GitOperationKind.Fetch, new { repository = id })).State == "succeeded", "check remote branch");
            var behind = await Detail(monitor, id);
            Require(behind.RemoteCheckFresh && behind.Repository.Behind == 1 && behind.PullSource == "origin/master" && !behind.CanPull && !behind.Repository.CanPush &&
                originalHead == (await Git(repo, "rev-parse", "HEAD")).Trim(), "fetch discovers updates without changing the working branch");
            Require((await Run(monitor, GitOperationKind.Pull, new { repository = id, revision = behind.Revision })).State == "failed",
                "local changes prevent pulling");
            Require((await Git(repo, "diff", "--cached", "--name-only")).Trim() == "base.txt", "blocked pull preserves staged changes");
            await Git(repo, "restore", "--staged", "--worktree", "--", "base.txt");
            var readyToPull = await Detail(monitor, id);
            Require(readyToPull.CanPull, "clean branch can fast-forward");
            Require((await Run(monitor, GitOperationKind.Pull, new { repository = id, revision = behind.Revision })).State == "failed",
                "stale pull confirmation is rejected");
            var ignoredConflict = Path.Combine(repo, "ignored", "conflict.txt");
            File.WriteAllText(ignoredConflict, "local ignored version");
            Require((await Run(monitor, GitOperationKind.Pull, new { repository = id, revision = readyToPull.Revision })).State == "failed" &&
                File.ReadAllText(ignoredConflict) == "local ignored version" &&
                originalHead == (await Git(repo, "rev-parse", "HEAD")).Trim(), "pull preserves an ignored file in its way");
            File.Delete(ignoredConflict);
            Require((await Run(monitor, GitOperationKind.Pull, new { repository = id, revision = readyToPull.Revision })).State == "succeeded",
                "confirmed pull fast-forwards");
            var pulled = await Detail(monitor, id);
            Require(pulled.Repository.Behind == 0 && !pulled.CanPull && File.ReadAllText(Path.Combine(repo, "remote.txt")) == "remote update",
                "pull updates the branch and working tree");

            File.WriteAllText(Path.Combine(peer, "remote.txt"), "later remote update");
            await Git(peer, "commit", "-am", "Later remote update");
            await Git(peer, "push", "origin", "master");
            clock.Advance(TimeSpan.FromMinutes(59));
            Require((await Run(monitor, GitOperationKind.Fetch, new { repository = id })).State == "succeeded",
                "repeat check uses cached result");
            var cached = await Detail(monitor, id);
            Require(cached.RemoteCheckFresh && cached.Repository.Behind == 0, "no second fetch within an hour");
            clock.Advance(TimeSpan.FromMinutes(1));
            Require(!(await Detail(monitor, id)).RemoteCheckFresh, "remote check expires exactly after an hour");
            Require((await Run(monitor, GitOperationKind.Fetch, new { repository = id })).State == "succeeded",
                "expired check fetches again");
            var rechecked = await Detail(monitor, id);
            Require(rechecked.RemoteCheckFresh && rechecked.Repository.Behind == 1, "new remote update becomes visible after expiry");

            await Git(repo, "remote", "set-url", "origin", "https://name:secret@example.invalid/owner/app.git?credential=secret");
            var redacted = await Detail(monitor, id);
            Require(redacted.Repository.RemoteUrl == "https://example.invalid/owner/app.git" && !redacted.RemoteCheckFresh,
                "remote credentials redacted and a changed remote URL has its own cache");
            await Git(repo, "branch", "local-tracking");
            await Git(repo, "branch", "--set-upstream-to=local-tracking", "master");
            var localUpstream = await Detail(monitor, id);
            Require(localUpstream.Repository.Ahead is null && !localUpstream.Repository.CanPush,
                "a local upstream is not counted as a pushed branch");
            for (int i = 0; i < 7; i++)
                await Git(code, "init", "-b", "master", "project-" + i);
            var firstPage = (GitRepositoryPage)(await monitor.ListAsync(Json(new { }), Token))!;
            Require(firstPage.Repositories.Length == 6 && firstPage.NextCursor is not null, "first repository page");
            var secondPage = (GitRepositoryPage)(await monitor.ListAsync(Json(new { cursor = firstPage.NextCursor }), Token))!;
            Require(secondPage.Repositories.Length == 2 && secondPage.NextCursor is null &&
                firstPage.Repositories.Select(row => row.Id).Intersect(secondPage.Repositories.Select(row => row.Id)).Count() == 0,
                "repository continuation without duplicates");
            Console.WriteLine("PASS: Git discovery and pagination, ignore rules, commits, pushes, one-hour remote checks, safe fast-forward pulls, and URL redaction");
        }
        finally
        {
            var parent = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Path.GetTempPath())) + Path.DirectorySeparatorChar;
            if (temporary.FullName.StartsWith(parent + "hako-git-checks-", StringComparison.OrdinalIgnoreCase))
            {
                foreach (var file in temporary.EnumerateFiles("*", SearchOption.AllDirectories))
                    if (file.IsReadOnly) file.IsReadOnly = false;
                temporary.Delete(recursive: true);
            }
        }
    }

    private static async Task<GitRepositoryDetail> Detail(GitRepositoryMonitor monitor, string id) =>
        (GitRepositoryDetail)(await monitor.DetailAsync(Json(new { repository = id }), Token))!;

    private static async Task<GitOperation> Run(GitRepositoryMonitor monitor, GitOperationKind kind, object parameters)
    {
        var operation = (GitOperation)(await monitor.StartAsync(Json(parameters), kind, Token))!;
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(20));
        while (operation.State == "running")
        {
            await Task.Delay(50, timeout.Token);
            operation = (GitOperation)(await monitor.OperationAsync(Json(new { operation = operation.Id }), timeout.Token))!;
        }
        if (operation.State == "unknown") throw new Exception(operation.Message);
        return operation;
    }

    private static async Task<string> Git(string directory, params string[] arguments)
    {
        var result = await GitCommand.RunAsync(directory, Token, arguments);
        Require(result.ExitCode == 0, "fixture git " + arguments[0]);
        return result.Output;
    }
    private static JsonElement Json(object value) => JsonSerializer.SerializeToElement(value);

    private sealed class TestClock : TimeProvider
    {
        private DateTimeOffset now = DateTimeOffset.UnixEpoch;
        public override DateTimeOffset GetUtcNow() => now;
        public void Advance(TimeSpan elapsed) => now += elapsed;
    }

    private static void Require(bool condition, string operation)
    {
        if (!condition) throw new Exception("Git check failed: " + operation);
    }
}
