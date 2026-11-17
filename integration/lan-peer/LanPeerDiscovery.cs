using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;

namespace Mahjong.Plugin.Dalamud.Networking;

/// <summary>
/// Broadcasts presence on active IPv4 subnets. This is intentionally a presence-only
/// protocol: no hand, tile, score, opponent, game-state or action data is exchanged.
/// Users join the same UU virtual LAN manually; the local IPv4 subnet is the discovery boundary.
/// </summary>
public sealed class LanPeerDiscovery : IDisposable
{
    public const int DefaultPort = 47721;
    private const string Protocol = "doman-mahjong-peer-v4";
    private const int MaxPacketBytes = 2048;
    private static readonly TimeSpan PeerExpiry = TimeSpan.FromSeconds(8);
    private static readonly TimeSpan BroadcastInterval = TimeSpan.FromSeconds(2);

    private readonly Func<bool> enabled;
    private readonly Func<string> accountType;
    private readonly Func<bool> shareHandsConsent;
    private readonly string instanceId = Guid.NewGuid().ToString("N");
    private readonly ConcurrentDictionary<string, LanPeerInfo> peers = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task receiverTask;
    private readonly Task broadcasterTask;
    private string lastError = string.Empty;

    public LanPeerDiscovery(Func<bool> enabled, Func<string> accountType, Func<bool> shareHandsConsent)
    {
        this.enabled = enabled;
        this.accountType = accountType;
        this.shareHandsConsent = shareHandsConsent;
        receiverTask = Task.Run(() => ReceiveLoopAsync(lifetime.Token));
        broadcasterTask = Task.Run(() => BroadcastLoopAsync(lifetime.Token));
    }

    public string InstanceId => instanceId;

    public string AccountType => NormalizeAccountType(accountType());

    public IReadOnlyList<LanPeerInfo> Peers => peers.Values
        .OrderBy(p => p.InstanceId, StringComparer.Ordinal)
        .ToArray();

    /// <summary>Same sorted roster is shown on every client: local instance plus visible LAN peers.</summary>
    public IReadOnlyList<LanPeerInfo> Roster
    {
        get
        {
            if (!enabled())
                return Array.Empty<LanPeerInfo>();

            var all = peers.Values.ToList();
            all.Add(new LanPeerInfo(
                instanceId,
                AccountType,
                "本机",
                typeof(LanPeerDiscovery).Assembly.GetName().Version?.ToString() ?? "unknown",
                shareHandsConsent(),
                DateTimeOffset.UtcNow));
            return all.OrderBy(p => p.InstanceId, StringComparer.Ordinal).ToArray();
        }
    }

    public bool AllFourConsented
    {
        get
        {
            var roster = Roster;
            return roster.Count == 4 && roster.All(p => p.ShareHandsConsent);
        }
    }

    public bool IsConsentedPeer(string instanceId, string accountRole) =>
        peers.TryGetValue(instanceId, out var peer) &&
        peer.AccountType == accountRole &&
        peer.ShareHandsConsent;

    public string LastError => Volatile.Read(ref lastError);

    private async Task BroadcastLoopAsync(CancellationToken cancellationToken)
    {
        using var sender = new UdpClient(AddressFamily.InterNetwork) { EnableBroadcast = true };
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                PruneExpiredPeers();
                if (enabled())
                {
                    long sentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                    var frame = new PresenceFrame(
                        Protocol,
                        instanceId,
                        AccountType,
                        typeof(LanPeerDiscovery).Assembly.GetName().Version?.ToString() ?? "unknown",
                        shareHandsConsent(),
                        sentAt);
                    byte[] payload = JsonSerializer.SerializeToUtf8Bytes(frame);
                    bool sendFailed = false;
                    foreach (var endpoint in GetBroadcastEndpoints())
                    {
                        try { await sender.SendAsync(payload, payload.Length, endpoint).ConfigureAwait(false); }
                        catch (SocketException ex)
                        {
                            sendFailed = true;
                            Volatile.Write(ref lastError, $"UDP send {endpoint}: {ex.Message}");
                        }
                    }
                    if (!sendFailed)
                        Volatile.Write(ref lastError, string.Empty);
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (Exception ex) { Volatile.Write(ref lastError, $"Broadcast: {ex.Message}"); }

            try { await Task.Delay(BroadcastInterval, cancellationToken).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
        }
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                using var listener = new UdpClient(AddressFamily.InterNetwork);
                listener.Client.ExclusiveAddressUse = false;
                listener.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
                listener.Client.Bind(new IPEndPoint(IPAddress.Any, DefaultPort));

                while (!cancellationToken.IsCancellationRequested)
                {
                    var datagram = await listener.ReceiveAsync(cancellationToken).ConfigureAwait(false);
                    if (!enabled() || datagram.Buffer.Length is 0 or > MaxPacketBytes)
                        continue;
                    if (!IsLocalSubnetPeer(datagram.RemoteEndPoint.Address))
                        continue;

                    PresenceFrame? frame;
                    try { frame = JsonSerializer.Deserialize<PresenceFrame>(datagram.Buffer); }
                    catch (JsonException) { continue; }

                    if (frame is null || frame.Protocol != Protocol || frame.InstanceId == instanceId)
                        continue;
                    if (string.IsNullOrWhiteSpace(frame.InstanceId) ||
                        frame.InstanceId.Length > 64 ||
                        string.IsNullOrWhiteSpace(frame.PluginVersion) ||
                        frame.PluginVersion.Length > 32 ||
                        !IsValidAccountType(frame.AccountType))
                        continue;

                    long now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                    long oldestAccepted = now - (long)TimeSpan.FromSeconds(30).TotalMilliseconds;
                    long newestAccepted = now + (long)TimeSpan.FromSeconds(30).TotalMilliseconds;
                    if (frame.SentAtUnixMs < oldestAccepted || frame.SentAtUnixMs > newestAccepted)
                        continue;

                    peers[frame.InstanceId] = new LanPeerInfo(
                        frame.InstanceId,
                        frame.AccountType,
                        datagram.RemoteEndPoint.Address.ToString(),
                        frame.PluginVersion,
                        frame.ShareHandsConsent,
                        DateTimeOffset.UtcNow);
                    Volatile.Write(ref lastError, string.Empty);
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (SocketException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (Exception ex)
            {
                Volatile.Write(ref lastError, $"UDP receive: {ex.Message}");
                try { await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken).ConfigureAwait(false); }
                catch (OperationCanceledException) { break; }
            }
        }
    }

    private void PruneExpiredPeers()
    {
        DateTimeOffset cutoff = DateTimeOffset.UtcNow - PeerExpiry;
        foreach (var pair in peers)
            if (pair.Value.LastSeenUtc < cutoff)
                peers.TryRemove(pair.Key, out _);
    }

    private static bool IsLocalSubnetPeer(IPAddress remote)
    {
        if (remote.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(remote))
            return false;

        byte[] remoteBytes = remote.GetAddressBytes();
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (adapter.OperationalStatus != OperationalStatus.Up ||
                adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback)
                continue;

            IPInterfaceProperties properties;
            try { properties = adapter.GetIPProperties(); }
            catch (NetworkInformationException) { continue; }

            foreach (var unicast in properties.UnicastAddresses)
            {
                IPAddress localAddress = unicast.Address;
                IPAddress? maskAddress = unicast.IPv4Mask;
                if (localAddress.AddressFamily != AddressFamily.InterNetwork || maskAddress is null)
                    continue;

                byte[] localBytes = localAddress.GetAddressBytes();
                byte[] maskBytes = maskAddress.GetAddressBytes();
                if (localBytes.Length != 4 || maskBytes.Length != 4)
                    continue;

                bool sameSubnet = true;
                for (int i = 0; i < 4; i++)
                {
                    if ((localBytes[i] & maskBytes[i]) != (remoteBytes[i] & maskBytes[i]))
                    {
                        sameSubnet = false;
                        break;
                    }
                }
                if (sameSubnet)
                    return true;
            }
        }

        return false;
    }

    private static IEnumerable<IPEndPoint> GetBroadcastEndpoints()
    {
        var endpoints = new HashSet<string>(StringComparer.Ordinal);
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (adapter.OperationalStatus != OperationalStatus.Up ||
                adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback)
                continue;

            IPInterfaceProperties properties;
            try { properties = adapter.GetIPProperties(); }
            catch (NetworkInformationException) { continue; }

            foreach (var unicast in properties.UnicastAddresses)
            {
                var address = unicast.Address;
                var mask = unicast.IPv4Mask;
                if (address.AddressFamily != AddressFamily.InterNetwork || mask is null)
                    continue;

                byte[] ip = address.GetAddressBytes();
                byte[] subnet = mask.GetAddressBytes();
                if (ip.Length != 4 || subnet.Length != 4)
                    continue;

                var broadcast = new byte[4];
                for (int i = 0; i < 4; i++)
                    broadcast[i] = (byte)(ip[i] | ~subnet[i]);

                var endpointAddress = new IPAddress(broadcast);
                if (IPAddress.IsLoopback(endpointAddress) || endpointAddress.Equals(IPAddress.Any))
                    continue;
                if (endpoints.Add(endpointAddress.ToString()))
                    yield return new IPEndPoint(endpointAddress, DefaultPort);
            }
        }
    }

    private static string NormalizeAccountType(string? value) =>
        value is "大号" or "BIG" ? "大号" : "小号";

    private static bool IsValidAccountType(string? value) =>
        value is "大号" or "小号";

    public void Dispose()
    {
        lifetime.Cancel();
        try { Task.WhenAll(receiverTask, broadcasterTask).Wait(TimeSpan.FromSeconds(2)); }
        catch (AggregateException) { }
        lifetime.Dispose();
    }

    private sealed record PresenceFrame(
        string Protocol,
        string InstanceId,
        string AccountType,
        string PluginVersion,
        bool ShareHandsConsent,
        long SentAtUnixMs);
}

public sealed record LanPeerInfo(
    string InstanceId,
    string AccountType,
    string Address,
    string PluginVersion,
    bool ShareHandsConsent,
    DateTimeOffset LastSeenUtc);
