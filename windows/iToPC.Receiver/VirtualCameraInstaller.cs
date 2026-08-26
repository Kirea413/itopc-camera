using Microsoft.Win32;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;

namespace iToPC.Receiver;

internal static class VirtualCameraInstaller
{
    private const string SourceClsid = "{f74cfe1b-8b5a-4a3f-9694-7d73024d8f97}";

    public static bool IsSupported => Environment.OSVersion.Version.Build >= 22000;

    public static bool IsInstalled
    {
        get
        {
            using var root = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
            using var key = root.OpenSubKey($@"Software\Classes\CLSID\{SourceClsid}\InprocServer32");
            var path = key?.GetValue(null) as string;
            return !string.IsNullOrWhiteSpace(path) && File.Exists(path);
        }
    }

    public static Task<int> InstallAsync(string payloadDirectory) =>
        RunElevatedScriptAsync("install-vcam.ps1", payloadDirectory);

    public static Task<int> UninstallAsync(string payloadDirectory) =>
        RunElevatedScriptAsync("uninstall-vcam.ps1", payloadDirectory);

    private static async Task<int> RunElevatedScriptAsync(string scriptName, string payloadDirectory)
    {
        var scriptPath = Path.Combine(payloadDirectory, scriptName);
        if (!File.Exists(scriptPath)) throw new FileNotFoundException("仮想カメラスクリプトがありません。", scriptPath);

        var info = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden
        };
        info.ArgumentList.Add("-NoProfile");
        info.ArgumentList.Add("-ExecutionPolicy");
        info.ArgumentList.Add("Bypass");
        info.ArgumentList.Add("-File");
        info.ArgumentList.Add(scriptPath);
        if (scriptName.Equals("install-vcam.ps1", StringComparison.OrdinalIgnoreCase))
        {
            info.ArgumentList.Add("-PayloadDirectory");
            info.ArgumentList.Add(payloadDirectory);
        }

        try
        {
            using var process = Process.Start(info)
                ?? throw new InvalidOperationException("管理者インストーラーを起動できませんでした。");
            await process.WaitForExitAsync();
            return process.ExitCode;
        }
        catch (Win32Exception error) when (error.NativeErrorCode == 1223)
        {
            throw new OperationCanceledException("ユーザーが管理者権限の確認をキャンセルしました。", error);
        }
    }
}
