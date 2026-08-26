using System.Net;
using System.Net.Sockets;

namespace iToPC.Receiver;

internal sealed class UsbMuxProxy : IAsyncDisposable
{
    private readonly int _devicePort;
    private CancellationTokenSource? _cancellation;
    private TcpClient? _deviceClient;
    private TcpClient? _playerClient;
    private TcpListener? _listener;
    private Task? _proxyTask;

    public int LocalPort { get; private set; }

    public UsbMuxProxy(int devicePort)
    {
        _devicePort = devicePort;
    }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        if (_cancellation is not null) throw new InvalidOperationException("USBプロキシは既に起動しています。");

        _cancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        _deviceClient = await UsbMuxClient.ConnectFirstUsbDeviceAsync(_devicePort, _cancellation.Token);
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start(1);
        LocalPort = ((IPEndPoint)_listener.LocalEndpoint).Port;
        _proxyTask = RunAsync(_cancellation.Token);
    }

    private async Task RunAsync(CancellationToken cancellationToken)
    {
        if (_listener is null || _deviceClient is null) return;
        _playerClient = await _listener.AcceptTcpClientAsync(cancellationToken);
        _playerClient.NoDelay = true;

        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        var playerStream = _playerClient.GetStream();
        var deviceStream = _deviceClient.GetStream();
        var deviceToPlayer = deviceStream.CopyToAsync(playerStream, 256 * 1024, linked.Token);
        var playerToDevice = playerStream.CopyToAsync(deviceStream, 16 * 1024, linked.Token);

        await Task.WhenAny(deviceToPlayer, playerToDevice);
        linked.Cancel();
        try { await Task.WhenAll(deviceToPlayer, playerToDevice); }
        catch (OperationCanceledException) { }
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
        }

        _cancellation?.Dispose();
        _cancellation = null;
    }
}

