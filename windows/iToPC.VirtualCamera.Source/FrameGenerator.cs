using System.IO.MemoryMappedFiles;

namespace VCamNetSampleSourceAOT;

/// <summary>
/// Copies the newest NV12 frame published by the iToPC receiver into a
/// Media Foundation sample. The frame file uses two slots, so the writer can
/// publish the next frame without blocking the virtual-camera consumer.
/// </summary>
public sealed unsafe class FrameGenerator : IDisposable
{
    private readonly SharedFrameReader _reader = new();
    private ulong _frameCount;

    public bool HasD3DManager => false;
    public ulong FrameCount => _frameCount;

    public HRESULT SetD3DManager(nint manager, uint width, uint height) => Constants.S_OK;

    public HRESULT EnsureRenderTarget(uint width, uint height)
    {
        if (width != Shared.Width || height != Shared.Height)
            return Constants.E_INVALIDARG;

        return Constants.S_OK;
    }

    public IComObject<IMFSample> Generate(IComObject<IMFSample> sample, Guid format)
    {
        ArgumentNullException.ThrowIfNull(sample);
        if (format != Constants.MFVideoFormat_NV12)
            throw new NotSupportedException("iToPC virtual camera only exposes NV12 frames.");

        using var buffer = sample.GetBufferByIndex(0);
        buffer.WithLock((scanline, length, _) =>
        {
            _reader.CopyLatest(scanline, checked((int)length));
        });
        buffer.SetCurrentLength(Shared.FrameSize);
        _frameCount++;
        return sample;
    }

    public void Dispose()
    {
        _reader.Dispose();
        GC.SuppressFinalize(this);
    }
}

internal sealed unsafe class SharedFrameReader : IDisposable
{
    private MemoryMappedFile? _mapping;
    private MemoryMappedViewAccessor? _view;
    private DateTime _nextOpenAttemptUtc;

    public void CopyLatest(nint destination, int capacity)
    {
        if (destination == 0 || capacity < Shared.FrameSize)
            throw new ArgumentException("The Media Foundation sample is smaller than one NV12 frame.");

        if (!EnsureOpen() || !TryCopy(destination))
            WriteStandbyFrame(destination);
    }

    private bool EnsureOpen()
    {
        if (_view is not null) return true;
        if (DateTime.UtcNow < _nextOpenAttemptUtc) return false;
        _nextOpenAttemptUtc = DateTime.UtcNow.AddSeconds(1);

        try
        {
            var stream = new FileStream(
                Shared.FrameFilePath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            _mapping = MemoryMappedFile.CreateFromFile(
                stream,
                mapName: null,
                capacity: 0,
                MemoryMappedFileAccess.Read,
                HandleInheritability.None,
                leaveOpen: false);
            _view = _mapping.CreateViewAccessor(0, 0, MemoryMappedFileAccess.Read);
            return true;
        }
        catch
        {
            DisposeMapping();
            return false;
        }
    }

    private bool TryCopy(nint destination)
    {
        var view = _view;
        if (view is null) return false;

        try
        {
            if (view.ReadUInt32(0) != Shared.FrameMagic ||
                view.ReadInt32(4) != 1 ||
                view.ReadInt32(8) != Shared.Width ||
                view.ReadInt32(12) != Shared.Height ||
                view.ReadInt32(16) != Shared.FrameSize)
            {
                return false;
            }

            for (var attempt = 0; attempt < 2; attempt++)
            {
                var sequenceBefore = view.ReadInt64(24);
                var slot = view.ReadInt32(20);
                if (sequenceBefore <= 0 || slot is < 0 or > 1) return false;

                byte* viewBase = null;
                view.SafeMemoryMappedViewHandle.AcquirePointer(ref viewBase);
                try
                {
                    var source = viewBase + view.PointerOffset + Shared.HeaderSize + slot * Shared.FrameSize;
                    Buffer.MemoryCopy(source, (void*)destination, Shared.FrameSize, Shared.FrameSize);
                }
                finally
                {
                    view.SafeMemoryMappedViewHandle.ReleasePointer();
                }

                if (sequenceBefore == view.ReadInt64(24)) return true;
            }
            return false;
        }
        catch
        {
            DisposeMapping();
            return false;
        }
    }

    private static void WriteStandbyFrame(nint destination)
    {
        var frame = new Span<byte>((void*)destination, Shared.FrameSize);
        frame[..(Shared.Width * Shared.Height)].Fill(16);
        frame[(Shared.Width * Shared.Height)..].Fill(128);
    }

    private void DisposeMapping()
    {
        Interlocked.Exchange(ref _view, null)?.Dispose();
        Interlocked.Exchange(ref _mapping, null)?.Dispose();
    }

    public void Dispose()
    {
        DisposeMapping();
        GC.SuppressFinalize(this);
    }
}
