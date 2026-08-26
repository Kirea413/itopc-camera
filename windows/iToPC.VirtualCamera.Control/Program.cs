using DirectN;
using DirectN.Extensions;
using DirectN.Extensions.Com;

namespace iToPC.VirtualCamera.Control;

internal static class Program
{
    private const string SourceClsid = "f74cfe1b-8b5a-4a3f-9694-7d73024d8f97";
    private const string FriendlyName = "iToPC Camera";

    private static int Main(string[] args)
    {
        var command = args.FirstOrDefault()?.ToLowerInvariant() ?? "create";
        if (command is not ("create" or "remove"))
        {
            Console.Error.WriteLine("Usage: iToPC.VirtualCamera.Control <create|remove>");
            return 2;
        }

        try
        {
            Functions.MFStartup(Constants.MF_VERSION, 0).ThrowOnError();
            try
            {
                var result = Functions.MFCreateVirtualCamera(
                    MFVirtualCameraType.MFVirtualCameraType_SoftwareCameraSource,
                    MFVirtualCameraLifetime.MFVirtualCameraLifetime_System,
                    MFVirtualCameraAccess.MFVirtualCameraAccess_CurrentUser,
                    PWSTR.From(FriendlyName),
                    PWSTR.From($"{{{SourceClsid}}}"),
                    0,
                    0,
                    out var camera);
                result.ThrowOnError();

                using var virtualCamera = new ComObject<IMFVirtualCamera>(camera);
                if (command == "create")
                {
                    virtualCamera.Object.Start(null).ThrowOnError();
                    Console.WriteLine("iToPC virtual camera created.");
                }
                else
                {
                    virtualCamera.Object.Remove().ThrowOnError();
                    Console.WriteLine("iToPC virtual camera removed.");
                }
            }
            finally
            {
                Functions.MFShutdown().ThrowOnError();
            }
            return 0;
        }
        catch (Exception error)
        {
            Console.Error.WriteLine(error);
            return 1;
        }
    }
}

