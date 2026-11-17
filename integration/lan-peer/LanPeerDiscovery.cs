using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Mahjong.Core;

namespace Mahjong.Plugin.Dalamud.Networking;

/// <summary>
/// Presence and same-table matching for the four privately controlled clients.
/// The game snapshot has no player-name fields, so private-table matching uses a
/// stable public match key plus the exact 2-big/2-small client roster.
/// </summary>
public sealed class LanPeerDiscovery : IDisposable
{
    public const int DefaultPort = 47721;
    private const string Protocol = "doman-mahjong-peer-v5";
    private const int MaxPacketBytes = 2048;
    private static readonly TimeSpan PeerExpiry = TimeSpan.FromSeconds(8);
    private static readonly TimeSpan BroadcastInterval = TimeSpan.FromSeconds(2);

    private static readonly SnapshotObservationFlags RequiredPublicObservations =
        SnapshotObservationFlags.SeatInfo |
        SnapshotObservationFlags.PublicDiscardTiles |
        SnapshotObservationFlags.PublicDiscardRedIdentity |
        SnapshotObservationFlags.PublicTedashi |
        SnapshotObservationFlags.OpponentMelds |
        SnapshotObservationFlags.OpponentRiichi |
        SnapshotObservationFlags.RoundContext |
        SnapshotObservationFlags.Dora |
        SnapshotObservationFlags.Wall;

    private readonly Func<bool> enabled;
    private readonly Func<string> accountType;
    private readonly Func<StateSnapshot?> snapshotAccessor;
    private readonly string instanceId = Guid.NewGuid().ToString("N");
    private readonly ConcurrentDictionary<string, LanPeerInfo> peers = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task receiverTask;
    private readonly Task broadcasterTask;
    private string lastError = string.Empty;

    public LanPeerDiscovery(
        Func<bool> enabled,
        Func<string> accountType,
        Func<StateSnapshot?> snapshotAccessor)
    {
        this.enabled = enabled;
        this.accountType = accountType;
        this.snapshotAccessor = snapshotAccessor;
        receiverTask = Task.Run(() => ReceiveLoopAsync(lifetime.Token));
        broadcasterTask = Task.Run(() => BroadcastLoopAsync(lifetime.Token));
    }

    public string InstanceId => instanceId;
    public string AccountType => NormalizeAccountType(accountType());
    public string CurrentMatchKey => ComputeMatchKey(snapshotAccessor());

    public IReadOnlyList<LanPeerInfo> Peers
    {
        get
        {
            PruneExpiredPeers();
            return peers.Values.OrderBy(p => p.InstanceId, StringComparer.Ordinal).ToArray();
        }
    }

    public IReadOnlyList<LanPeerInfo> Roster
    {
        get
        {
            if (!enabled())
                return Array.Empty<LanPeerInfo>();

            var all = Peers.ToList();
            all.Add(new LanPeerInfo(
                instanceId,
                AccountType,
                "本机",
                typeof(LanPeerDiscovery).Assembly.GetName().Version?.ToString() ?? "unknown",
                CurrentMatchKey,
                DateTimeOffset.UtcNow));
            return all.OrderBy(p => p.InstanceId, StringComparer.Ordinal).ToArray();
        }
    }

    public IReadOnlyList<LanPeerInfo> SameTableRoster
    {
        get
        {
            string key = CurrentMatchKey;
            if (string.IsNullOrEmpty(key))
                return Array.Empty<LanPeerInfo>();
            return Roster.Where(p => p.MatchKey == key).ToArray();
        }
    }

    /// <summary>
    /// Conservative private-table gate: exactly four plugin clients on the trusted LAN,
    /// all reporting the same verified match key, with exactly two big and two small roles.
    /// </summary>
    public bool IsPrivateFourAccountTable
    {
        get
        {
            var all = Roster;
            if (all.Count != 4)
                return false;
            string key = CurrentMatchKey;
            if (string.IsNullOrEmpty(key))
                return false;
            var table = all.Where(p => p.MatchKey == key).ToArray();
            return table.Length == 4
                && table.Count(p => p.AccountType == "大号") == 2
                && table.Count(p => p.AccountType == "小号") == 2;
        }
    }

    public int BigAccountOrdinal
    {
        get
        {
            if (!IsPrivateFourAccountTable || AccountType != "大号")
                return 0;
            var bigs = SameTableRoster.Where(p => p.AccountType == "大号")
                .OrderBy(p => p.InstanceId, StringComparer.Ordinal).ToArray();
            int index = Array.FindIndex(bigs, p => p.InstanceId == instanceId);
            return index < 0 ? 0 : index + 1;
        }
    }

    public bool IsSameTablePeer(string peerInstanceId, string peerAccountType, string matchKey) =>
        IsPrivateFourAccountTable &&
        peers.TryGetValue(peerInstanceId, out var peer) &&
        peer.AccountType == peerAccountType &&
        peer.MatchKey == matchKey &&
        matchKey == CurrentMatchKey;

    public string LastError => Volatile.Read(ref lastError);

    private static string ComputeMatchKey(StateSnapshot? snapshot)
    {
        if (snapshot is null ||
            !snapshot.PublicStateConsistent ||
            snapshot.SeatWind is not (>= 0 and <= 3) ||
            snapshot.Seats.Count != 4 ||
            snapshot.Scores.Count != 4 ||
            (snapshot.Observations & RequiredPublicObservations) != RequiredPublicObservations)
            return string.Empty;

        // Stable through a hand: do not include rivers, wall count or current turn.
        // These fields can update a few frames apart on separate clients.
        string scoreVector = string.Join(",", snapshot.Scores.Order());
        string value = string.Join("|",
            snapshot.RoundWind,
            snapshot.Kyoku ?? 0,
            snapshot.Honba,
            snapshot.RiichiSticks,
            snapshot.DealerSeat,
            snapshot.InitialDealerSeat ?? -1,
            snapshot.ScheduledRounds ?? -1,
            scoreVector);
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(value)));
    }

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
                    var frame = new PresenceFrame(
                        Protocol,
                        instanceId,
                        AccountType,
                        typeof(LanPeerDiscovery).Assembly.GetName().Version?.ToString() ?? "unknown",
                        CurrentMatchKey,
                        DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
                    byte[] payload = JsonSerializer.SerializeToUtf8Bytes(frame);
                    foreach (var endpoint in GetBroadcastEndpoints())
                    {
                        try { await sender.SendAsync(payload, payload.Length, endpoint).ConfigureAwait(false); }
                        catch (SocketException ex) { Volatile.Write(ref lastError, $"UDP send {endpoint}: {ex.Message}"); }
                    }
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
                    if (!enabled() || datagram.Buffer.Length is 0 or > MaxPacketBytes ||
                        !IsLocalSubnetPeer(datagram.RemoteEndPoint.Address))
                        continue;

                    PresenceFrame? frame;
                    try { frame = JsonSerializer.Deserialize<PresenceFrame>(datagram.Buffer); }
                    catch (JsonException) { continue; }

                    if (frame is null || frame.Protocol != Protocol || frame.InstanceId == instanceId)
                        continue;
                    if (string.IsNullOrWhiteSpace(frame.InstanceId) || frame.InstanceId.Length > 64 ||
                        string.IsNullOrWhiteSpace(frame.PluginVersion) || frame.PluginVersion.Length > 32 ||
                        !IsValidAccountType(frame.AccountType) ||
                        (!string.IsNullOrEmpty(frame.MatchKey) &&
                         (frame.MatchKey.Length != 64 || !frame.MatchKey.All(Uri.IsHexDigit))))
                        continue;

                    long now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                    if (frame.SentAtUnixMs < now - 30_000 || frame.SentAtUnixMs > now + 30_000)
                        continue;

                    peers[frame.InstanceId] = new LanPeerInfo(
                        frame.InstanceId,
                        frame.AccountType,
                        datagram.RemoteEndPoint.Address.ToString(),
                        frame.PluginVersion,
                        frame.MatchKey ?? string.Empty,
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
                IPAddress local = unicast.Address;
                IPAddress? mask = unicast.IPv4Mask;
                if (local.AddressFamily != AddressFamily.InterNetwork || mask is null)
                    continue;
                byte[] localBytes = local.GetAddressBytes();
                byte[] maskBytes = mask.GetAddressBytes();
                bool same = true;
                for (int i = 0; i < 4; i++)
                    if ((localBytes[i] & maskBytes[i]) != (remoteBytes[i] & maskBytes[i]))
                    { same = false; break; }
                if (same) return true;
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
                if (ip.Length != 4 || subnet.Length != 4) continue;
                byte[] broadcast = new byte[4];
                for (int i = 0; i < 4; i++) broadcast[i] = (byte)(ip[i] | ~subnet[i]);
                var endpointAddress = new IPAddress(broadcast);
                if (!IPAddress.IsLoopback(endpointAddress) && !endpointAddress.Equals(IPAddress.Any) &&
                    endpoints.Add(endpointAddress.ToString()))
                    yield return new IPEndPoint(endpointAddress, DefaultPort);
            }
        }
    }

    private static string NormalizeAccountType(string? value) => value is "大号" or "BIG" ? "大号" : "小号";
    private static bool IsValidAccountType(string? value) => value is "大号" or "小号";

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
        string? MatchKey,
        long SentAtUnixMs);
}

public sealed record LanPeerInfo(
    string InstanceId,
    string AccountType,
    string Address,
    string PluginVersion,
    string MatchKey,
    DateTimeOffset LastSeenUtc);
