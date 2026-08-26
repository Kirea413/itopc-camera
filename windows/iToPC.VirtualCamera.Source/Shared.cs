namespace VCamNetSampleSourceAOT;

public static class Shared
{
    public const string CLSID_iToPC = "f74cfe1b-8b5a-4a3f-9694-7d73024d8f97";
    public const int Width = 1920;
    public const int Height = 1080;
    public const int Fps = 60;
    public const int FrameSize = Width * Height * 3 / 2;
    public const int HeaderSize = 4096;
    public const uint FrameMagic = 0x43505449; // "ITPC" little-endian

    public static string FrameFilePath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "iToPC",
        "frames.nv12");
}
