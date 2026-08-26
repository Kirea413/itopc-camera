using System.IO;
using System.IO.MemoryMappedFiles;

namespace iToPC.Receiver;

internal sealed unsafe class SharedFrameWriter : IDisposable
{
    public const int Width = 1920;
    public const int Height = 1080;
    public const int Fps = 60;
    public const int FrameSize = Width * Height * 3 / 2;
    public const int HeaderSize = 4096;
    private const int FileSize = HeaderSize + FrameSize * 2;
    private const uint Magic = 0x43505449;

    private readonly FileStream _stream;
    private readonly MemoryMappedFile _mapping;
    private readonly MemoryMappedViewAccessor _view;
    private long _sequence;
    private int _nextSlot;

    public static string FrameFilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "iToPC",
        "frames.nv12");

    public SharedFrameWriter()
    {
        var directory = Path.GetDirectoryName(FrameFilePath)
            ?? throw new InvalidOperationException("共有フレームフォルダを解決できません。");
        Directory.CreateDirectory(directory);

        _stream = new FileStream(
            FrameFilePath,
            FileMode.OpenOrCreate,
            FileAccess.ReadWrite,
            FileShare.ReadWrite | FileShare.Delete);
        _stream.SetLength(FileSize);
        _mapping = MemoryMappedFile.CreateFromFile(
            _stream,
            mapName: null,
            capacity: FileSize,
            MemoryMappedFileAccess.ReadWrite,
            HandleInheritability.None,
            leaveOpen: true);
        _view = _mapping.CreateViewAccessor(0, FileSize, MemoryMappedFileAccess.ReadWrite);

        _view.Write(0, Magic);
        _view.Write(4, 1);
        _view.Write(8, Width);
        _view.Write(12, Height);
        _view.Write(16, FrameSize);
        _view.Write(20, 0);
        _view.Write(24, 0L);
        _view.Write(32, 0L);
        WriteStandbyFrames();
    }

    public void Publish(ReadOnlySpan<byte> frame)
    {
        if (frame.Length != FrameSize)
            throw new ArgumentException($"NV12 frame must contain exactly {FrameSize} bytes.", nameof(frame));

        var slot = _nextSlot;
        byte* viewBase = null;
        _view.SafeMemoryMappedViewHandle.AcquirePointer(ref viewBase);
        try
        {
            var destination = new Span<byte>(
                viewBase + _view.PointerOffset + HeaderSize + slot * FrameSize,
                FrameSize);
            frame.CopyTo(destination);
        }
        finally
        {
            _view.SafeMemoryMappedViewHandle.ReleasePointer();
        }

        Thread.MemoryBarrier();
        _view.Write(20, slot);
        _view.Write(32, DateTime.UtcNow.Ticks);
        _view.Write(24, ++_sequence);
        _nextSlot = 1 - slot;
    }

    public void Publish(byte[] frame) => Publish(frame.AsSpan());

    private void WriteStandbyFrames()
    {
        byte* viewBase = null;
        _view.SafeMemoryMappedViewHandle.AcquirePointer(ref viewBase);
        try
        {
            for (var slot = 0; slot < 2; slot++)
            {
                var frame = new Span<byte>(
                    viewBase + _view.PointerOffset + HeaderSize + slot * FrameSize,
                    FrameSize);
                frame[..(Width * Height)].Fill(16);
                frame[(Width * Height)..].Fill(128);
            }
        }
        finally
        {
            _view.SafeMemoryMappedViewHandle.ReleasePointer();
        }
    }

    public void Dispose()
    {
        _view.Dispose();
        _mapping.Dispose();
        _stream.Dispose();
    }
}
