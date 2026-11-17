using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;
using Mahjong.Core;

namespace Mahjong.Plugin.Dalamud.Networking;

/// <summary>
/// Exchanges each controlled client's own hand only when the LAN discovery layer has
/// verified exactly four same-table clients with two big and two small roles.
/// No manual consent checkbox is used because this feature is scoped to the user's
/// four private clients and is disabled automatically when the roster is incomplete.
/// </summary>
public sealed class FourPlayerHandSync : IDisposable
{
    public const int DefaultPort = 47723;
    private const string Protocol = "doman-private-four-hands-v1";
    private const int MaxPacketBytes = 4096;
    private static readonly TimeSpan PeerExpiry = TimeSpan.FromSeconds(8);
    private static readonly TimeSpan Heartbeat = TimeSpan.FromSeconds(2);
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    private readonly LanPeerDiscovery peers;
    private readonly Func<bool> enabled;
    private readonly Func<StateSnapshot?> snapshotAccessor;
    private readonly ConcurrentDictionary<string, SharedHandInfo> remoteHands = new();
    private readonly CancellationTokenSource lifetime = new();
    private readonly Task senderTask;
    private readonly Task receiverTask;
    private string lastError = string.Empty;
    private long framesSent;
    private long framesReceived;

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

    public FourPlayerHandSync(
        LanPeerDiscovery peers,
        Func<bool> enabled,
        Func<StateSnapshot?> snapshotAccessor)
    {
        this.peers = peers;
        this.enabled = enabled;
        this.snapshotAccessor = snapshotAccessor;
        senderTask = Task.Run(() => SendLoopAsync(lifetime.Token));
        receiverTask = Task.Run(() => ReceiveLoopAsync(lifetime.Token));
    }

    public bool IsPrivateFourAccountTable => enabled() && peers.IsPrivateFourAccountTable;
    public int SameTableClientCount => enabled() ? peers.SameTableRoster.Count : 0;
    public string LastError => Volatile.Read(ref lastError);
    public long FramesSent => Interlocked.Read(ref framesSent);
    public long FramesReceived => Interlocked.Read(ref framesReceived);

    public IReadOnlyList<SharedHandInfo> RemoteHands
    {
        get
        {
            PruneExpired();
            if (!IsPrivateFourAccountTable || !TryGetLocalSnapshot(out _, out var matchKey))
            {
                remoteHands.Clear();
                return Array.Empty<SharedHandInfo>();
            }

            return remoteHands.Values
                .Where(x => x.MatchKey == matchKey &&
                            peers.IsSameTablePeer(x.InstanceId, x.AccountType, x.MatchKey))
                .OrderBy(x => x.SeatWind)
                .ToArray();
        }
    }

    private bool TryGetLocalSnapshot(out StateSnapshot snapshot, out string matchKey)
    {
        snapshot = snapshotAccessor()!;
        matchKey = peers.CurrentMatchKey;
        if (snapshot is null || !IsReadySnapshot(snapshot) ||
            snapshot.SeatWind is not (>= 0 and <= 3) || string.IsNullOrEmpty(matchKey))
            return false;
        return true;
    }

    private static bool IsReadySnapshot(StateSnapshot snapshot) =>
        snapshot.PublicStateConsistent &&
        snapshot.Hand.Count is 13 or 14 &&
        snapshot.HandIsRed.Count == snapshot.Hand.Count &&
        snapshot.Seats.Count == 4 &&
        snapshot.Scores.Count == 4 &&
        (snapshot.Observations & RequiredPublicObservations) == RequiredPublicObservations;

    private async Task SendLoopAsync(CancellationToken cancellationToken)
    {
        using var sender = new UdpClient(AddressFamily.InterNetwork) { EnableBroadcast = true };
        string? lastStateKey = null;
        DateTimeOffset lastSent = DateTimeOffset.MinValue;

        while (!cancellationToken.IsCancellationRequested)
        {
            try
            {
                PruneExpired();
                if (IsPrivateFourAccountTable && TryGetLocalSnapshot(out var snapshot, out var matchKey))
                {
                    string stateKey = $"{matchKey}:{snapshot.Hand.Count}:" +
                        string.Join(",", snapshot.Hand.Select(x => x.Id)) + ":" +
                        string.Join(",", snapshot.HandIsRed.Select(x => x ? 1 : 0));
                    DateTimeOffset now = DateTimeOffset.UtcNow;
                    if (stateKey != lastStateKey || now - lastSent >= Heartbeat)
                    {
                        var frame = new HandFrame(
                            Protocol,
                            peers.InstanceId,
                            peers.AccountType,
                            Environment.MachineName.Length > 32 ? Environment.MachineName[..32] : Environment.MachineName,
                            typeof(FourPlayerHandSync).Assembly.GetName().Version?.ToString() ?? "unknown",
                            now.ToUnixTimeMilliseconds(),
                            matchKey,
                            snapshot.SeatWind!.Value,
                            snapshot.RoundWind,
                            snapshot.Kyoku ?? 1,
                            snapshot.Hand.Select(x => (int)x.Id).ToArray(),
                            snapshot.HandIsRed.ToArray());

                        byte[] payload = JsonSerializer.SerializeToUtf8Bytes(frame, JsonOptions);
                        if (payload.Length > MaxPacketBytes)
                            throw new InvalidDataException("Hand snapshot packet exceeded size limit.");

                        foreach (var endpoint in GetBroadcastEndpoints())
                            await sender.SendAsync(payload, payload.Length, endpoint).ConfigureAwait(false);

                        lastStateKey = stateKey;
                        lastSent = now;
                        Interlocked.Increment(ref framesSent);
                        Volatile.Write(ref lastError, string.Empty);
                    }
                }
                else
                {
                    lastStateKey = null;
                    remoteHands.Clear();
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (Exception ex) { Volatile.Write(ref lastError, $"Private hand sync send: {ex.Message}"); }

            try { await Task.Delay(150, cancellationToken).ConfigureAwait(false); }
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
                    if (datagram.Buffer.Length is 0 or > MaxPacketBytes ||
                        !IsLocalSubnetPeer(datagram.RemoteEndPoint.Address) ||
                        !IsPrivateFourAccountTable ||
                        !TryGetLocalSnapshot(out _, out var localMatchKey))
                        continue;

                    HandFrame? frame;
                    try { frame = JsonSerializer.Deserialize<HandFrame>(datagram.Buffer, JsonOptions); }
                    catch (JsonException) { continue; }

                    if (frame is null || !IsValidFrame(frame) ||
                        frame.InstanceId == peers.InstanceId ||
                        frame.MatchKey != localMatchKey ||
                        !peers.IsSameTablePeer(frame.InstanceId, frame.AccountType, frame.MatchKey))
                        continue;

                    long now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                    if (frame.SentAtUnixMs < now - 30_000 || frame.SentAtUnixMs > now + 30_000)
                        continue;

                    remoteHands[frame.InstanceId] = new SharedHandInfo(
                        frame.InstanceId,
                        frame.AccountType,
                        frame.DisplayName,
                        datagram.RemoteEndPoint.Address.ToString(),
                        frame.SeatWind,
                        frame.RoundWind,
                        frame.Kyoku,
                        frame.HandTiles.ToArray(),
                        frame.HandIsRed.ToArray(),
                        frame.MatchKey,
                        DateTimeOffset.UtcNow);
                    Interlocked.Increment(ref framesReceived);
                    Volatile.Write(ref lastError, string.Empty);
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (SocketException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (Exception ex)
            {
                Volatile.Write(ref lastError, $"Private hand sync receive: {ex.Message}");
                try { await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken).ConfigureAwait(false); }
                catch (OperationCanceledException) { break; }
            }
        }
    }

    private static bool IsValidFrame(HandFrame frame)
    {
        if (frame.Protocol != Protocol ||
            string.IsNullOrWhiteSpace(frame.InstanceId) || frame.InstanceId.Length > 64 ||
            frame.AccountType is not ("大号" or "小号") ||
            string.IsNullOrWhiteSpace(frame.DisplayName) || frame.DisplayName.Length > 32 ||
            string.IsNullOrWhiteSpace(frame.PluginVersion) || frame.PluginVersion.Length > 32 ||
            frame.MatchKey is null || frame.MatchKey.Length != 64 ||
            frame.SeatWind is < 0 or > 3 || frame.RoundWind is < 0 or > 3 ||
            frame.Kyoku is < 1 or > 4 || frame.HandTiles is null ||
            frame.HandTiles.Length is not (13 or 14) || frame.HandIsRed is null ||
            frame.HandIsRed.Length != frame.HandTiles.Length ||
            frame.HandTiles.Any(x => x is < 0 or > 33))
            return false;

        var counts = new int[34];
        for (int i = 0; i < frame.HandTiles.Length; i++)
        {
            int tile = frame.HandTiles[i];
            if (++counts[tile] > 4) return false;
            if (frame.HandIsRed[i] && tile is not (4 or 13 or 22)) return false;
        }
        return frame.MatchKey.All(Uri.IsHexDigit);
    }

    private void PruneExpired()
    {
        DateTimeOffset cutoff = DateTimeOffset.UtcNow - PeerExpiry;
        foreach (var pair in remoteHands)
            if (pair.Value.LastSeenUtc < cutoff ||
                !peers.IsSameTablePeer(pair.Key, pair.Value.AccountType, pair.Value.MatchKey))
                remoteHands.TryRemove(pair.Key, out _);
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
                IPAddress address = unicast.Address;
                IPAddress? mask = unicast.IPv4Mask;
                if (address.AddressFamily != AddressFamily.InterNetwork || mask is null) continue;
                byte[] ip = address.GetAddressBytes();
                byte[] subnet = mask.GetAddressBytes();
                if (ip.Length != 4 || subnet.Length != 4) continue;
                byte[] broadcast = new byte[4];
                for (int i = 0; i < 4; i++) broadcast[i] = (byte)(ip[i] | ~subnet[i]);
                IPAddress target = new(broadcast);
                if (!IPAddress.IsLoopback(target) && !target.Equals(IPAddress.Any) && endpoints.Add(target.ToString()))
                    yield return new IPEndPoint(target, DefaultPort);
            }
        }
    }

    private static bool IsLocalSubnetPeer(IPAddress remote)
    {
        if (remote.AddressFamily != AddressFamily.InterNetwork || IPAddress.IsLoopback(remote)) return false;
        byte[] remoteBytes = remote.GetAddressBytes();
        foreach (var adapter in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (adapter.OperationalStatus != OperationalStatus.Up ||
                adapter.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            IPInterfaceProperties properties;
            try { properties = adapter.GetIPProperties(); }
            catch (NetworkInformationException) { continue; }
            foreach (var unicast in properties.UnicastAddresses)
            {
                IPAddress local = unicast.Address;
                IPAddress? mask = unicast.IPv4Mask;
                if (local.AddressFamily != AddressFamily.InterNetwork || mask is null) continue;
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

    public void Dispose()
    {
        lifetime.Cancel();
        try { Task.WhenAll(senderTask, receiverTask).Wait(TimeSpan.FromSeconds(2)); }
        catch (AggregateException) { }
        lifetime.Dispose();
    }

    private sealed record HandFrame(
        string Protocol,
        string InstanceId,
        string AccountType,
        string DisplayName,
        string PluginVersion,
        long SentAtUnixMs,
        string MatchKey,
        int SeatWind,
        int RoundWind,
        int Kyoku,
        int[] HandTiles,
        bool[] HandIsRed);
}

public sealed record SharedHandInfo(
    string InstanceId,
    string AccountType,
    string DisplayName,
    string Address,
    int SeatWind,
    int RoundWind,
    int Kyoku,
    int[] HandTiles,
    bool[] HandIsRed,
    string MatchKey,
    DateTimeOffset LastSeenUtc);
