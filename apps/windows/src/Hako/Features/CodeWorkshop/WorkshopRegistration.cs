using System;
using System.Linq;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Hako.Core;

namespace Hako.Platform;

internal sealed record WorkshopRegistration(int ProtocolVersion, string[] Addresses, int Port)
{
    internal static WorkshopRegistration Snapshot(int port) => new(1, port > 0 ? AddressesOnLAN() : [], port);

    private static string[] AddressesOnLAN() => NetworkInterface.GetAllNetworkInterfaces()
        .Where(value => value.OperationalStatus == OperationalStatus.Up && value.NetworkInterfaceType != NetworkInterfaceType.Loopback)
        .OrderByDescending(value => value.GetIPProperties().GatewayAddresses.Any(gateway => IsPrivateIPv4(gateway.Address)))
        .SelectMany(value => value.GetIPProperties().UnicastAddresses)
        .Select(value => value.Address).Where(IsPrivateIPv4).Select(value => value.ToString()).Distinct().Take(16).ToArray();

    internal static bool IsPrivateIPv4(IPAddress address)
    {
        if (address.AddressFamily != AddressFamily.InterNetwork) return false;
        var b = address.GetAddressBytes();
        return b[0] == 10 || b[0] == 172 && b[1] is >= 16 and <= 31 || b[0] == 192 && b[1] == 168;
    }

    internal static async Task<WorkshopRegistration> ReadAsync(string? profile, CancellationToken token)
    {
        if (profile is null) return Snapshot(0);
        using var budget = CancellationTokenSource.CreateLinkedTokenSource(token);
        budget.CancelAfter(TimeSpan.FromSeconds(2));
        try
        {
            var value = await LocalRpc.CallAsync(LocalRpc.MainPipe(profile), LocalRpc.Request("workshop.registration"), budget.Token);
            return value.Deserialize<WorkshopRegistration>(WorkshopProtocol.Json)!;
        }
        catch (AgentActionException) { return Snapshot(0); }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { return Snapshot(0); }
    }
}
