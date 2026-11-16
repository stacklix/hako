using System;
using System.IO;
using System.Text.Json;

namespace Hako.Core;

internal static partial class AgentGuardianControl
{
    internal static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase };
    internal static string DirectoryFor(string profile) => Path.Combine(profile, "guardian");
    internal static string FileFor(string profile, string name) => Path.Combine(DirectoryFor(profile), name);
    internal static T? Read<T>(string path) where T : class
    {
        if (!File.Exists(path)) return null;
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (stream.Length > 131072) throw new InvalidDataException("Guardian metadata is too large.");
        return JsonSerializer.Deserialize<T>(stream, Json);
    }
    internal static void Write<T>(string path, T value)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            { JsonSerializer.Serialize(stream, value, Json); stream.Flush(true); }
            File.Move(temporary, path, true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    internal sealed record Maintenance(int ProcessId, DateTimeOffset StartedAt);
    internal static void BeginMaintenance(string profile, int processId) =>
        Write(FileFor(profile, "maintenance.json"), new Maintenance(processId, DateTimeOffset.UtcNow));
    internal static void EndMaintenance(string profile) => File.Delete(FileFor(profile, "maintenance.json"));
    internal static void ManualExit(string profile, int processId)
    {
        try
        {
            var maintenance = Read<Maintenance>(FileFor(profile, "maintenance.json"));
            if (maintenance?.ProcessId == processId && DateTimeOffset.UtcNow - maintenance.StartedAt < TimeSpan.FromHours(1)) return;
            Write(FileFor(profile, "paused.json"), new { processId, time = DateTimeOffset.UtcNow });
        }
        catch (Exception error) when (error is IOException or InvalidDataException or UnauthorizedAccessException or JsonException)
        { System.Diagnostics.Debug.WriteLine(error.GetType().Name); }
    }
    internal static void Resume(string profile)
    {
        try { File.Delete(FileFor(profile, "paused.json")); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { System.Diagnostics.Debug.WriteLine(error.GetType().Name); }
    }
}

internal sealed record AgentGuardianOptions(string TargetPath, string ProfileDirectory, string Repository,
    int PollSeconds = 5, int UpdatePollSeconds = 300, int RestartDelaySeconds = 30)
{
    internal void Validate()
    {
        if (!Path.IsPathFullyQualified(TargetPath) || !Path.IsPathFullyQualified(ProfileDirectory) ||
            !System.Text.RegularExpressions.Regex.IsMatch(Repository, @"\A[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z") ||
            PollSeconds is < 1 or > 60 || UpdatePollSeconds is < 5 or > 86400 || RestartDelaySeconds is < 1 or > 3600)
            throw new InvalidDataException("Invalid guardian configuration.");
    }
}

internal sealed record AgentUpdateCandidate(string Path, string Sha256, long BuildId, string Version, DateTimeOffset? PublishedAt = null);
internal sealed record AgentPendingUpdate(string Path, string Sha256, string Version, DateTimeOffset CreatedAt, bool RestartAfterUpdate);
internal sealed record AgentInstallStamp(string Sha256, DateTimeOffset InstalledAt);
