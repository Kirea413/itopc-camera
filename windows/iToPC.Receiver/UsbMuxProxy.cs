using System.Buffers.Binary;
using System.IO;
using System.Net;
using System.Net.Sockets;

namespace iToPC.Receiver;

internal sealed class UsbMuxProxy : IAsyncDisposable
{
    private const int FrameHeaderSize = 24;
    private const int MaximumPayloadSize = 32 * 1024 * 1024;
    private static ReadOnlySpan<byte> FrameMagic => "ITPC"u8;

    private readonly int _devicePort;
    private readonly string? _wifiHost;
    private CancellationTokenSource? _cancellation;
    private TcpClient? _deviceClient;
    private TcpClient? _playerClient;
    private TcpListener? _listener;
    private Task? _proxyTask;

    public int LocalPort { get; private set; }

    public UsbMuxProxy(int devicePort, string? wifiHost = null)
    {
        _devicePort = devicePort;
        _wifiHost = wifiHost;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        if (_cancellation is not null) throw new InvalidOperationException("USBプロキシは既に起動しています。");

        _cancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        if (_wifiHost is null)
        {
            _deviceClient = await UsbMuxClient.ConnectFirstUsbDeviceAsync(_devicePort, _cancellation.Token);
        }
        else
        {
            _deviceClient = new TcpClient();
            await _deviceClient.ConnectAsync(_wifiHost, _devicePort, _cancellation.Token);
        }
        _deviceClient.NoDelay = true;
        _deviceClient.ReceiveBufferSize = 64 * 1024;
        _deviceClient.SendBufferSize = 64 * 1024;

        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start(1);
        LocalPort = ((IPEndPoint)_listener.LocalEndpoint).Port;
        _proxyTask = RunWithCleanupAsync(_cancellation.Token);
    }

    private async Task RunWithCleanupAsync(CancellationToken cancellationToken)
    {
        try
        {
            await RunAsync(cancellationToken);
        }
        finally
        {
            _playerClient?.Dispose();
            _deviceClient?.Dispose();
        }
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        if (_listener is null || _deviceClient is null) return;
        _playerClient = await _listener.AcceptTcpClientAsync(cancellationToken);
        _playerClient.NoDelay = true;
        _playerClient.ReceiveBufferSize = 64 * 1024;
        _playerClient.SendBufferSize = 64 * 1024;

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var playerStream = _playerClient.GetStream();
        var deviceStream = _deviceClient.GetStream();
        var prefix = new byte[4];
        if (!await ReadExactlyAsync(deviceStream, prefix, linked.Token)) return;

        if (!prefix.AsSpan().SequenceEqual(FrameMagic))
        {
            await playerStream.WriteAsync(prefix, linked.Token);
            await deviceStream.CopyToAsync(playerStream, 64 * 1024, linked.Token);
            return;
        }

        var frameQueue = new LatestFrameQueue(maximumFrames: 2);
        var reader = ReadFramedStreamAsync(deviceStream, frameQueue, linked.Token);
        var writer = WriteFramedStreamAsync(playerStream, frameQueue, linked.Token);
        await Task.WhenAny(reader, writer);
        linked.Cancel();
        frameQueue.Complete();
        try { await Task.WhenAll(reader, writer); }
        catch (OperationCanceledException) { }
    }

    private static async Task ReadFramedStreamAsync(
        Stream source,
        LatestFrameQueue frameQueue,
        CancellationToken cancellationToken)
    {
        var remainder = new byte[FrameHeaderSize - 4];
        while (!cancellationToken.IsCancellationRequested)
        {
            if (!await ReadExactlyAsync(source, remainder, cancellationToken)) break;
            if (remainder[0] != 1)
                throw new InvalidDataException($"未対応のiToPC転送プロトコルです (version {remainder[0]})。");

            var flags = remainder[1];
            var headerSize = BinaryPrimitives.ReadUInt16BigEndian(remainder.AsSpan(2, 2));
            var payloadSize = BinaryPrimitives.ReadUInt32BigEndian(remainder.AsSpan(4, 4));
            if (headerSize is < FrameHeaderSize or > 256)
                throw new InvalidDataException($"不正なフレームヘッダー長です ({headerSize})。");
            if (payloadSize is 0 or > MaximumPayloadSize)
                throw new InvalidDataException($"不正なフレームサイズです ({payloadSize})。");

            if (headerSize > FrameHeaderSize)
            {
                var extension = new byte[headerSize - FrameHeaderSize];
                if (!await ReadExactlyAsync(source, extension, cancellationToken)) break;
            }

            var payload = new byte[(int)payloadSize];
            if (!await ReadExactlyAsync(source, payload, cancellationToken)) break;
            frameQueue.Enqueue(payload, isKeyFrame: (flags & 1) != 0);

            var nextMagic = new byte[4];
            if (!await ReadExactlyAsync(source, nextMagic, cancellationToken)) break;
            if (!nextMagic.AsSpan().SequenceEqual(FrameMagic))
                throw new InvalidDataException("iToPCフレーム境界が壊れています。");
        }
        frameQueue.Complete();
    }

    private static async Task WriteFramedStreamAsync(
        Stream destination,
        LatestFrameQueue frameQueue,
        CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested)
        {
            var frame = await frameQueue.DequeueAsync(cancellationToken);
            if (frame is null) break;
            await destination.WriteAsync(frame, cancellationToken);
        }
    }

    private static async Task<bool> ReadExactlyAsync(
        Stream source,
        Memory<byte> destination,
        CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < destination.Length)
        {
            var read = await source.ReadAsync(destination[offset..], cancellationToken);
            if (read == 0) return false;
            offset += read;
        }
        return true;
    }

    public async ValueTask DisposeAsync()
    {
        _cancellation?.Cancel();
        _listener?.Stop();
        _playerClient?.Dispose();
        _deviceClient?.Dispose();

        if (_proxyTask is not null)
        {
            try { await _proxyTask; }
            catch (OperationCanceledException) { }
            catch (ObjectDisposedException) { }
            catch (SocketException) { }
            catch (IOException) { }
        }

        _cancellation?.Dispose();
        _cancellation = null;
    }

    private sealed class LatestFrameQueue
    {
        private readonly int _maximumFrames;
        private readonly Queue<byte[]> _frames = new();
        private readonly SemaphoreSlim _available = new(0);
        private bool _droppingUntilKeyFrame = true;
        private bool _completed;

        public LatestFrameQueue(int maximumFrames)
        {
            _maximumFrames = maximumFrames;
        }

        public void Enqueue(byte[] frame, bool isKeyFrame)
        {
            lock (_frames)
            {
                if (_completed) return;
                if (_droppingUntilKeyFrame)
                {
                    if (!isKeyFrame) return;
                    _droppingUntilKeyFrame = false;
                }

                if (_frames.Count >= _maximumFrames)
                {
                    _frames.Clear();
                    _droppingUntilKeyFrame = true;
                    if (!isKeyFrame) return;
                    _droppingUntilKeyFrame = false;
                }

                _frames.Enqueue(frame);
                _available.Release();
            }
        }

        public async Task<byte[]?> DequeueAsync(CancellationToken cancellationToken)
        {
            while (true)
            {
                await _available.WaitAsync(cancellationToken);
                lock (_frames)
                {
                    if (_frames.Count > 0) return _frames.Dequeue();
                    if (_completed) return null;
                }
            }
        }

        public void Complete()
        {
            lock (_frames)
            {
                if (_completed) return;
                _completed = true;
                _available.Release();
            }
        }
    }
}
