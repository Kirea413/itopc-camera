using System.Diagnostics;
using System.IO;
using System.IO.Pipes;

namespace iToPC.Receiver;

internal sealed class RawFramePump : IAsyncDisposable
{
    private readonly Process _process;
    private readonly SharedFrameWriter _writer;
    private readonly NamedPipeServerStream _framePipe;
    private readonly CancellationTokenSource _cancellation = new();
    private readonly Task _readTask;
    private readonly Task _exitTask;
    private readonly Task _watchdogTask;
    private readonly long _startedAtTicks = DateTime.UtcNow.Ticks;
    private long _lastFrameTicks;

    public event Action<string>? LogReceived;
    public event Action<int>? Exited;

    public RawFramePump(
        string ffmpegPath,
        IEnumerable<string> arguments,
        Action<string>? logReceived = null,
        Action<int>? exited = null)
    {
        if (logReceived is not null) LogReceived += logReceived;
        if (exited is not null) Exited += exited;
        _writer = new SharedFrameWriter();
        var pipeName = $"itopc-frames-{Environment.ProcessId}-{Guid.NewGuid():N}";
        var pipePath = $@"\\.\pipe\{pipeName}";
        _framePipe = new NamedPipeServerStream(
            pipeName,
            PipeDirection.In,
            maxNumberOfServerInstances: 1,
            PipeTransmissionMode.Byte,
            PipeOptions.Asynchronous,
            inBufferSize: 1024 * 1024,
            outBufferSize: 0);
        var startInfo = new ProcessStartInfo
        {
            FileName = ffmpegPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = false,
            RedirectStandardError = true
        };
        foreach (var argument in arguments)
        {
            startInfo.ArgumentList.Add(argument == "pipe:1" ? pipePath : argument);
        }

        _process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        _process.ErrorDataReceived += (_, args) =>
        {
            if (!string.IsNullOrWhiteSpace(args.Data)) LogReceived?.Invoke(args.Data);
        };
        if (!_process.Start()) throw new InvalidOperationException("ffmpegを起動できませんでした。");
        _process.BeginErrorReadLine();

        _readTask = Task.Run(() => ReadFrames(_cancellation.Token));
        _exitTask = ObserveExitAsync();
        _watchdogTask = WatchdogAsync(_cancellation.Token);
    }

    private void ReadFrames(CancellationToken cancellationToken)
    {
        _framePipe.WaitForConnection();
        while (!cancellationToken.IsCancellationRequested)
        {
            if (!_writer.ReadAndPublish(_framePipe, cancellationToken)) break;
            Interlocked.Exchange(ref _lastFrameTicks, DateTime.UtcNow.Ticks);
        }
    }

    private async Task WatchdogAsync(CancellationToken cancellationToken)
    {
        while (!cancellationToken.IsCancellationRequested && !_process.HasExited)
        {
            await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
            var lastFrameTicks = Interlocked.Read(ref _lastFrameTicks);
            var referenceTicks = lastFrameTicks == 0 ? _startedAtTicks : lastFrameTicks;
            var timeout = lastFrameTicks == 0 ? TimeSpan.FromSeconds(15) : TimeSpan.FromSeconds(5);
            if (DateTime.UtcNow - new DateTime(referenceTicks, DateTimeKind.Utc) <= timeout) continue;

            LogReceived?.Invoke("映像データが停止したため、受信処理を再起動できる状態に戻します。");
            if (!_process.HasExited) _process.Kill(entireProcessTree: true);
            return;
        }
    }

    private async Task ObserveExitAsync()
    {
        await _process.WaitForExitAsync();
        if (!_cancellation.IsCancellationRequested) Exited?.Invoke(_process.ExitCode);
    }

    public async ValueTask DisposeAsync()
    {
        _cancellation.Cancel();
        if (!_process.HasExited)
        {
            _process.Kill(entireProcessTree: true);
        }
        _framePipe.Dispose();

        try { await Task.WhenAll(_readTask, _exitTask, _watchdogTask); }
        catch (OperationCanceledException) { }
        catch (IOException) when (_cancellation.IsCancellationRequested) { }
        catch (ObjectDisposedException) when (_cancellation.IsCancellationRequested) { }

        _process.Dispose();
        _writer.Dispose();
        _cancellation.Dispose();
    }
}
