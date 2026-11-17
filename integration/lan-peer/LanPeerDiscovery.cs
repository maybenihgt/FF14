using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Mahjong.Plugin.Dalamud.Networking;

/// <summary>
/// Broadcasts a small, authenticated presence packet on IPv4 LAN interfaces.
/// Deliberately carries identity/presence only: no hand, tile, score, opponent,
/// game-state, or action data is part of this protocol.
/// </summary>
public sealed class LanPeerDiscovery : IDisposable
{
    public const int DefaultPort = 47721;
    private const string Protocol = "doman-mahjong-peer-v1";
    private const int MaxPacketBytes = 2048;
    private static readonly TimeSpan PeerExpiry = TimeSpan.FromSeconds(8);
    private static readonly TimeSpan BroadcastInterval = TimeSpan.FromSeconds(2);

    private readonly Func<bool> enabled;
    private readonly Func<string> accountLabel;
    private readonly Func<string> roomCode;
    private readonly string instanceId = Guid.NewGuid().ToString("N");
    private readonly ConcurrentDictionary<string, LanPeerInfo> peers = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task receiverTask;
    private readonly Task broadcasterTask;
    private string lastError = string.Empty;

    public LanPeerDiscovery(Func<bool> enabled, Func<string> accountLabel, Func<string> roomCode)
    {
        this.enabled = enabled;
        this.accountLabel = accountLabel;
        this.roomCode = roomCode;
        receiverTask = Task.Run(() => ReceiveLoopAsync(lifetime.Token));
        broadcasterTask = Task.Run(() => BroadcastLoopAsync(lifetime.Token));
    }

    public IReadOnlyList<LanPeerInfo> Peers => peers.Values
        .OrderBy(p => p.AccountLabel, StringComparer.Ordinal)
        .ThenBy(p => p.Address, StringComparer.Ordinal)
        .ToArray();

    public string LastError => Volatile.Read(ref lastError);

    private async Task BroadcastLoopAsync(CancellationToken cancellationToken)
    {
        using var sender = new UdpClient(AddressFamily.InterNetwork) { EnableBroadcast = true };
        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                PruneExpiredPeers();
                string key = roomCode().Trim();
                if (enabled() && key.Length >= 12)
                {
                    string label = NormalizeLabel(accountLabel());
                    long sentAt = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                    string auth = Sign(key, instanceId, label, sentAt);
                    var frame = new PresenceFrame(Protocol, instanceId, label,
                        typeof(LanPeerDiscovery).Assembly.GetName().Version?.ToString() ?? "unknown",
                        sentAt, auth);
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

                    string key = roomCode().Trim();
                    if (key.Length < 12)
                        continue;

                    PresenceFrame? frame;
                    try { frame = JsonSerializer.Deserialize<PresenceFrame>(datagram.Buffer); }
                    catch (JsonException) { continue; }
                    if (frame is null || frame.Protocol != Protocol || frame.InstanceId == instanceId)
                        continue;
                    if (!IsValidLabel(frame.AccountLabel))
                        continue;

                    long now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                    long oldestAccepted = now - (long)TimeSpan.FromSeconds(30).TotalMilliseconds;
                    long newestAccepted = now + (long)TimeSpan.FromSeconds(30).TotalMilliseconds;
                    if (frame.SentAtUnixMs < oldestAccepted || frame.SentAtUnixMs > newestAccepted)
                        continue;

                    string expected = Sign(key, frame.InstanceId, frame.AccountLabel, frame.SentAtUnixMs);
                    if (!FixedTimeEquals(expected, frame.Auth))
                        continue;

                    peers[frame.InstanceId] = new LanPeerInfo(
                        frame.InstanceId,
                        frame.AccountLabel,
                        datagram.RemoteEndPoint.Address.ToString(),
                        frame.PluginVersion,
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

    private static IEnumerable<IPEndPoint> GetBroadcastEndpoints()
    {
        var endpoints = new HashSet<string>(StringComparer.Ordinal);
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (adapter.OperationalStatus != OperationalStatus.Up || adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback)
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

    private static string NormalizeLabel(string? value) => IsValidLabel(value) ? value! : "UNASSIGNED";

    private static bool IsValidLabel(string? value) =>
        value is "MAIN_A" or "MAIN_B" or "ALT_C" or "ALT_D" or "UNASSIGNED";

    private static string Sign(string key, string instance, string label, long sentAt)
    {
        string canonical = $"{Protocol}\n{instance}\n{label}\n{sentAt}";
        using var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(key));
        return Convert.ToHexString(hmac.ComputeHash(Encoding.UTF8.GetBytes(canonical)));
    }

    private static bool FixedTimeEquals(string expectedHex, string? receivedHex)
    {
        if (string.IsNullOrWhiteSpace(receivedHex)) return false;
        try
        {
            byte[] expected = Convert.FromHexString(expectedHex);
            byte[] received = Convert.FromHexString(receivedHex);
            return expected.Length == received.Length &&
                   CryptographicOperations.FixedTimeEquals(expected, received);
        }
        catch (FormatException) { return false; }
    }

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
        string AccountLabel,
        string PluginVersion,
        long SentAtUnixMs,
        string Auth);
}

public sealed record LanPeerInfo(
    string InstanceId,
    string AccountLabel,
    string Address,
    string PluginVersion,
    DateTimeOffset LastSeenUtc);
