using System.Diagnostics;
using System.IO;

namespace iToPC.Receiver;

internal sealed class RawFramePump : IAsyncDisposable
{
    private readonly Process _process;
    private readonly SharedFrameWriter _writer;
    private readonly CancellationTokenSource _cancellation = new();
    private readonly Task _readTask;
    private readonly Task _exitTask;

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
        var startInfo = new ProcessStartInfo
        {
            FileName = ffmpegPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true
        };
        foreach (var argument in arguments) startInfo.ArgumentList.Add(argument);

        _process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        _process.ErrorDataReceived += (_, args) =>
        {
            if (!string.IsNullOrWhiteSpace(args.Data)) LogReceived?.Invoke(args.Data);
        };
        if (!_process.Start()) throw new InvalidOperationException("ffmpegを起動できませんでした。");
        _process.BeginErrorReadLine();

        _readTask = ReadFramesAsync(_cancellation.Token);
        _exitTask = ObserveExitAsync();
    }

    private async Task ReadFramesAsync(CancellationToken cancellationToken)
    {
        var frame = new byte[SharedFrameWriter.FrameSize];
        var stream = _process.StandardOutput.BaseStream;
        while (!cancellationToken.IsCancellationRequested)
        {
            if (!await ReadExactlyAsync(stream, frame, cancellationToken)) break;
            _writer.Publish(frame);
        }
    }

    private async Task ObserveExitAsync()
    {
        await _process.WaitForExitAsync();
        if (!_cancellation.IsCancellationRequested) Exited?.Invoke(_process.ExitCode);
    }

    private static async Task<bool> ReadExactlyAsync(Stream stream, Memory<byte> destination, CancellationToken cancellationToken)
    {
        var offset = 0;
        while (offset < destination.Length)
        {
            var read = await stream.ReadAsync(destination[offset..], cancellationToken);
            if (read == 0) return false;
            offset += read;
        }
        return true;
    }

    public async ValueTask DisposeAsync()
    {
        _cancellation.Cancel();
        if (!_process.HasExited)
        {
            _process.Kill(entireProcessTree: true);
        }

        try { await Task.WhenAll(_readTask, _exitTask); }
        catch (OperationCanceledException) { }
        catch (IOException) when (_cancellation.IsCancellationRequested) { }

        _process.Dispose();
        _writer.Dispose();
        _cancellation.Dispose();
    }
}
