using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.IO.Compression;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;
using Mahjong.Core;

namespace Mahjong.Plugin.Dalamud.Networking;

/// <summary>
/// Shares a strict whitelist of public table information between consenting clients on the same
/// virtual LAN. Concealed hands, legal actions, private draw information, ura-dora and recommendations
/// are intentionally absent from the wire DTO.
/// </summary>
public sealed class PublicTableStateSync : IDisposable
{
    public const int DefaultPort = 47722;
    private const string Protocol = "doman-public-table-v1";
    private const int HeaderSize = 24;
    private const int ChunkSize = 900;
    private const int MaxFragments = 32;
    private const int MaxCompressedBytes = ChunkSize * MaxFragments;
    private const int MaxExpandedBytes = 64 * 1024;
    private const string PacketMagic = "DMP1";
    private static readonly TimeSpan PeerExpiry = TimeSpan.FromSeconds(8);
    private static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(2);
    private static readonly JsonSerializerOptions JsonOptions = new() { PropertyNameCaseInsensitive = true };

    private readonly string instanceId;
    private readonly Func<string> accountType;
    private readonly Func<bool> enabled;
    private readonly Func<StateSnapshot?> snapshotAccessor;
    private readonly ConcurrentDictionary<string, RemotePublicTableState> remoteStates = new();
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

    public PublicTableStateSync(
        string instanceId,
        Func<string> accountType,
        Func<bool> enabled,
        Func<StateSnapshot?> snapshotAccessor)
    {
        this.instanceId = instanceId;
        this.accountType = accountType;
        this.enabled = enabled;
        this.snapshotAccessor = snapshotAccessor;
        senderTask = Task.Run(() => SendLoopAsync(lifetime.Token));
        receiverTask = Task.Run(() => ReceiveLoopAsync(lifetime.Token));
    }

    public IReadOnlyList<RemotePublicTableState> RemoteStates
    {
        get
        {
            PruneExpired();
            return remoteStates.Values.OrderBy(x => x.AccountType, StringComparer.Ordinal)
                .ThenBy(x => x.Address, StringComparer.Ordinal).ToArray();
        }
    }

    public string LastError => Volatile.Read(ref lastError);
    public long FramesSent => Interlocked.Read(ref framesSent);
    public long FramesReceived => Interlocked.Read(ref framesReceived);

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
                if (enabled())
                {
                    StateSnapshot? snapshot = snapshotAccessor();
                    if (snapshot is not null && IsPublicSnapshotReady(snapshot))
                    {
                        string stateKey = $"{snapshot.HandId}:{snapshot.Revision}";
                        DateTimeOffset now = DateTimeOffset.UtcNow;
                        if (stateKey != lastStateKey || now - lastSent >= HeartbeatInterval)
                        {
                            var frame = PublicTableFrame.FromSnapshot(
                                Protocol, instanceId, NormalizeAccountType(accountType()),
                                typeof(PublicTableStateSync).Assembly.GetName().Version?.ToString() ?? "unknown",
                                now.ToUnixTimeMilliseconds(), snapshot);
                            await BroadcastFrameAsync(sender, frame, cancellationToken).ConfigureAwait(false);
                            lastStateKey = stateKey;
                            lastSent = now;
                            Interlocked.Increment(ref framesSent);
                        }
                    }
                    else
                    {
                        lastStateKey = null;
                    }
                }
                else
                {
                    lastStateKey = null;
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (Exception ex)
            {
                Volatile.Write(ref lastError, $"Public-state send: {ex.Message}");
            }

            try { await Task.Delay(150, cancellationToken).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
        }
    }

    private async Task BroadcastFrameAsync(UdpClient sender, PublicTableFrame frame, CancellationToken cancellationToken)
    {
        byte[] json = JsonSerializer.SerializeToUtf8Bytes(frame, JsonOptions);
        byte[] compressed = Compress(json);
        if (compressed.Length > MaxCompressedBytes)
        {
            Volatile.Write(ref lastError, $"Public state too large ({compressed.Length} compressed bytes).");
            return;
        }

        int fragmentCount = Math.Max(1, (compressed.Length + ChunkSize - 1) / ChunkSize);
        Guid frameId = Guid.NewGuid();
        var endpoints = GetBroadcastEndpoints().ToArray();
        if (endpoints.Length == 0)
        {
            Volatile.Write(ref lastError, "No active IPv4 broadcast interface.");
            return;
        }

        foreach (var endpoint in endpoints)
        {
            for (int index = 0; index < fragmentCount; index++)
            {
                int offset = index * ChunkSize;
                int count = Math.Min(ChunkSize, compressed.Length - offset);
                byte[] packet = new byte[HeaderSize + count];
                System.Text.Encoding.ASCII.GetBytes(PacketMagic, packet.AsSpan(0, 4));
                frameId.TryWriteBytes(packet.AsSpan(4, 16));
                BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(20, 2), (ushort)fragmentCount);
                BinaryPrimitives.WriteUInt16LittleEndian(packet.AsSpan(22, 2), (ushort)index);
                compressed.AsSpan(offset, count).CopyTo(packet.AsSpan(HeaderSize));
                await sender.SendAsync(packet, packet.Length, endpoint).ConfigureAwait(false);
            }
        }
        Volatile.Write(ref lastError, string.Empty);
    }

    private async Task ReceiveLoopAsync(CancellationToken cancellationToken)
    {
        var assemblies = new Dictionary<string, FragmentAssembly>(StringComparer.Ordinal);
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
                    if (!enabled() || datagram.Buffer.Length <= HeaderSize || datagram.Buffer.Length > HeaderSize + ChunkSize)
                        continue;
                    if (!IsLocalSubnetPeer(datagram.RemoteEndPoint.Address))
                        continue;

                    byte[] packet = datagram.Buffer;
                    if (System.Text.Encoding.ASCII.GetString(packet, 0, 4) != PacketMagic)
                        continue;
                    Guid frameId = new(packet.AsSpan(4, 16));
                    int fragmentCount = BinaryPrimitives.ReadUInt16LittleEndian(packet.AsSpan(20, 2));
                    int fragmentIndex = BinaryPrimitives.ReadUInt16LittleEndian(packet.AsSpan(22, 2));
                    if (fragmentCount is < 1 or > MaxFragments || fragmentIndex >= fragmentCount)
                        continue;

                    string key = $"{datagram.RemoteEndPoint.Address}:{frameId:N}";
                    if (!assemblies.TryGetValue(key, out var assembly))
                    {
                        if (assemblies.Count >= 64)
                        {
                            string oldest = assemblies.OrderBy(x => x.Value.CreatedUtc).First().Key;
                            assemblies.Remove(oldest);
                        }
                        assembly = new FragmentAssembly(fragmentCount, DateTimeOffset.UtcNow);
                        assemblies[key] = assembly;
                    }
                    if (assembly.Parts.Length != fragmentCount)
                    {
                        assemblies.Remove(key);
                        continue;
                    }

                    assembly.Add(fragmentIndex, packet.AsSpan(HeaderSize).ToArray());
                    if (assembly.ReceivedCount == fragmentCount)
                    {
                        assemblies.Remove(key);
                        byte[] compressed = assembly.Join();
                        if (compressed.Length <= MaxCompressedBytes)
                            AcceptFrame(compressed, datagram.RemoteEndPoint.Address);
                    }

                    foreach (var stale in assemblies.Where(x => DateTimeOffset.UtcNow - x.Value.CreatedUtc > TimeSpan.FromSeconds(4))
                                 .Select(x => x.Key).ToArray())
                        assemblies.Remove(stale);
                }
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (SocketException) when (cancellationToken.IsCancellationRequested) { break; }
            catch (Exception ex)
            {
                Volatile.Write(ref lastError, $"Public-state receive: {ex.Message}");
                try { await Task.Delay(TimeSpan.FromSeconds(2), cancellationToken).ConfigureAwait(false); }
                catch (OperationCanceledException) { break; }
            }
        }
    }

    private void AcceptFrame(byte[] compressed, IPAddress remoteAddress)
    {
        byte[] json = DecompressBounded(compressed);
        var frame = JsonSerializer.Deserialize<PublicTableFrame>(json, JsonOptions);
        if (frame is null || !IsValidFrame(frame) || frame.InstanceId == instanceId)
            return;

        long now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        if (frame.SentAtUnixMs < now - 30_000 || frame.SentAtUnixMs > now + 30_000)
            return;

        remoteStates[frame.InstanceId] = new RemotePublicTableState(
            frame.InstanceId,
            frame.AccountType,
            remoteAddress.ToString(),
            frame.PluginVersion,
            frame.RoundWind,
            frame.Kyoku,
            frame.Honba,
            frame.WallRemaining,
            frame.Scores.ToArray(),
            frame.DoraIndicators.ToArray(),
            frame.Seats.Select(x => x.DiscardCount).ToArray(),
            DateTimeOffset.UtcNow);
        Interlocked.Increment(ref framesReceived);
        Volatile.Write(ref lastError, string.Empty);
    }

    private static bool IsPublicSnapshotReady(StateSnapshot snapshot) =>
        snapshot.PublicStateConsistent &&
        snapshot.Seats.Count == 4 &&
        snapshot.Scores.Count == 4 &&
        (snapshot.Observations & RequiredPublicObservations) == RequiredPublicObservations;

    private static bool IsValidFrame(PublicTableFrame frame)
    {
        if (frame.Protocol != Protocol || string.IsNullOrWhiteSpace(frame.InstanceId) ||
            frame.InstanceId.Length > 64 || !IsValidAccountType(frame.AccountType) ||
            string.IsNullOrWhiteSpace(frame.PluginVersion) || frame.PluginVersion.Length > 32 ||
            !frame.PublicStateConsistent || frame.Scores is null || frame.Scores.Length != 4 ||
            frame.Seats is null || frame.Seats.Length != 4 ||
            frame.DoraIndicators is null || frame.DoraIndicators.Length > 5 ||
            frame.OurSeat is < 0 or > 3 || frame.DealerSeat is < 0 or > 3 ||
            frame.RoundWind is < 0 or > 3 || frame.Kyoku is < 1 or > 4 ||
            frame.WallRemaining is < 0 or > 70 || frame.TurnIndex is < 0 or > 100)
            return false;

        if (frame.Scores.Any(x => x is < -100_000 or > 1_000_000) ||
            frame.DoraIndicators.Any(x => x is < 0 or > 33))
            return false;

        foreach (var seat in frame.Seats)
        {
            if (seat is null || seat.Discards is null || seat.Discards.Length > 100 ||
                seat.DiscardIsRed is null || seat.DiscardIsTedashi is null || seat.DiscardWasCalled is null ||
                seat.DiscardIsRed.Length != seat.Discards.Length ||
                seat.DiscardIsTedashi.Length != seat.Discards.Length ||
                seat.DiscardWasCalled.Length != seat.Discards.Length ||
                seat.Melds is null || seat.Melds.Length > 5 ||
                seat.Discards.Any(x => x is < 0 or > 33))
                return false;

            foreach (var meld in seat.Melds)
            {
                if (meld is null || meld.Kind is < 0 or > 4 || meld.Tiles is null || meld.Tiles.Length is not (3 or 4) ||
                    meld.Tiles.Any(x => x is < 0 or > 33) ||
                    meld.ClaimedTile is < 0 or > 33 ||
                    meld.ClaimedFromSeat is < -1 or > 3)
                    return false;
            }
        }
        return true;
    }

    private static byte[] Compress(byte[] input)
    {
        using var output = new MemoryStream();
        using (var stream = new BrotliStream(output, CompressionLevel.Fastest, leaveOpen: true))
            stream.Write(input, 0, input.Length);
        return output.ToArray();
    }

    private static byte[] DecompressBounded(byte[] input)
    {
        using var source = new MemoryStream(input);
        using var stream = new BrotliStream(source, CompressionMode.Decompress);
        using var output = new MemoryStream();
        byte[] buffer = new byte[4096];
        int read;
        while ((read = stream.Read(buffer, 0, buffer.Length)) > 0)
        {
            if (output.Length + read > MaxExpandedBytes)
                throw new InvalidDataException("Public state frame exceeded size limit.");
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }

    private void PruneExpired()
    {
        DateTimeOffset cutoff = DateTimeOffset.UtcNow - PeerExpiry;
        foreach (var pair in remoteStates)
            if (pair.Value.LastSeenUtc < cutoff)
                remoteStates.TryRemove(pair.Key, out _);
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
                var broadcast = new byte[4];
                for (int i = 0; i < 4; i++)
                    broadcast[i] = (byte)(ip[i] | ~subnet[i]);
                var target = new IPAddress(broadcast);
                if (!IPAddress.IsLoopback(target) && !target.Equals(IPAddress.Any) && endpoints.Add(target.ToString()))
                    yield return new IPEndPoint(target, DefaultPort);
            }
        }
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

    private static string NormalizeAccountType(string? value) => value is "大号" or "BIG" ? "大号" : "小号";
    private static bool IsValidAccountType(string? value) => value is "大号" or "小号";

    public void Dispose()
    {
        lifetime.Cancel();
        try { Task.WhenAll(senderTask, receiverTask).Wait(TimeSpan.FromSeconds(2)); }
        catch (AggregateException) { }
        lifetime.Dispose();
    }

    private sealed class FragmentAssembly
    {
        public byte[]?[] Parts { get; }
        public DateTimeOffset CreatedUtc { get; }
        public int ReceivedCount { get; private set; }
        public FragmentAssembly(int count, DateTimeOffset createdUtc)
        {
            Parts = new byte[count][];
            CreatedUtc = createdUtc;
        }
        public void Add(int index, byte[] value)
        {
            if (Parts[index] is not null) return;
            Parts[index] = value;
            ReceivedCount++;
        }
        public byte[] Join()
        {
            using var output = new MemoryStream();
            foreach (var part in Parts)
                if (part is not null) output.Write(part, 0, part.Length);
            return output.ToArray();
        }
    }

    private sealed record PublicTableFrame(
        string Protocol,
        string InstanceId,
        string AccountType,
        string PluginVersion,
        long SentAtUnixMs,
        int OurSeat,
        int RoundWind,
        int Kyoku,
        int Honba,
        int RiichiSticks,
        int DealerSeat,
        int WallRemaining,
        int TurnIndex,
        int[] Scores,
        int[] DoraIndicators,
        PublicSeatFrame[] Seats,
        bool PublicStateConsistent)
    {
        public static PublicTableFrame FromSnapshot(
            string protocol, string instanceId, string accountType, string pluginVersion,
            long sentAtUnixMs, StateSnapshot snapshot)
        {
            // Whitelist only publicly visible table state. There are intentionally no properties
            // for concealed hand, red-hand identity, legal actions, ura-dora or recommendations.
            var seats = snapshot.Seats.Select(seat => new PublicSeatFrame(
                seat.Discards.Select(x => (int)x.Id).ToArray(),
                seat.DiscardIsRed.ToArray(),
                seat.DiscardIsTedashi.ToArray(),
                seat.DiscardWasCalled.ToArray(),
                seat.Melds.Select(meld => new PublicMeldFrame(
                    (int)meld.Kind,
                    meld.Tiles.Select(x => (int)x.Id).ToArray(),
                    meld.ClaimedTile is { } claimed ? (int?)claimed.Id : null,
                    meld.ClaimedFromSeat)).ToArray(),
                seat.Riichi,
                seat.RiichiDiscardIndex,
                seat.Ippatsu,
                seat.IsTenpaiCalled,
                seat.DiscardCount)).ToArray();

            return new PublicTableFrame(
                protocol, instanceId, accountType, pluginVersion, sentAtUnixMs,
                snapshot.OurSeat, snapshot.RoundWind, snapshot.Kyoku ?? 1, snapshot.Honba,
                snapshot.RiichiSticks, snapshot.DealerSeat, snapshot.WallRemaining,
                snapshot.TurnIndex, snapshot.Scores.ToArray(),
                snapshot.DoraIndicators.Select(x => (int)x.Id).ToArray(),
                seats, snapshot.PublicStateConsistent);
        }
    }

    private sealed record PublicSeatFrame(
        int[] Discards,
        bool[] DiscardIsRed,
        bool[] DiscardIsTedashi,
        bool[] DiscardWasCalled,
        PublicMeldFrame[] Melds,
        bool Riichi,
        int RiichiDiscardIndex,
        bool Ippatsu,
        bool IsTenpaiCalled,
        int DiscardCount);

    private sealed record PublicMeldFrame(
        int Kind,
        int[] Tiles,
        int? ClaimedTile,
        int ClaimedFromSeat);
}

public sealed record RemotePublicTableState(
    string InstanceId,
    string AccountType,
    string Address,
    string PluginVersion,
    int RoundWind,
    int Kyoku,
    int Honba,
    int WallRemaining,
    int[] Scores,
    int[] DoraIndicators,
    int[] DiscardCounts,
    DateTimeOffset LastSeenUtc);
