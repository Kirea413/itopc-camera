using Microsoft.Win32;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;

namespace iToPC.Receiver;

internal static class VirtualCameraInstaller
{
    private const string SourceClsid = "{f74cfe1b-8b5a-4a3f-9694-7d73024d8f97}";

    public static string InstallLogPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
        "iToPC",
        "virtual-camera-install.log");

    public static bool IsSupported => Environment.OSVersion.Version.Build >= 22000;

    public static bool IsInstalled
    {
        get
        {
            var path = GetInstalledSourcePath();
            return !string.IsNullOrWhiteSpace(path) && File.Exists(path);
        }
    }

    public static bool IsUpdateAvailable(string payloadDirectory)
    {
        var installedPath = GetInstalledSourcePath();
        var payloadPath = Path.Combine(payloadDirectory, "iToPC.VirtualCamera.Source.dll");
        if (string.IsNullOrWhiteSpace(installedPath) || !File.Exists(installedPath) || !File.Exists(payloadPath))
            return false;

        try
        {
            using var installedStream = new FileStream(installedPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var payloadStream = new FileStream(payloadPath, FileMode.Open, FileAccess.Read, FileShare.Read);
            return !SHA256.HashData(installedStream).SequenceEqual(SHA256.HashData(payloadStream));
        }
        catch
        {
            return true;
        }
    }

    private static string? GetInstalledSourcePath()
    {
        using var root = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using var key = root.OpenSubKey($@"Software\Classes\CLSID\{SourceClsid}\InprocServer32");
        return key?.GetValue(null) as string;
    }

    public static Task<int> InstallAsync(string payloadDirectory) =>
        RunElevatedScriptAsync("install-vcam.ps1", payloadDirectory);

    public static Task<int> UninstallAsync(string payloadDirectory) =>
        RunElevatedScriptAsync("uninstall-vcam.ps1", payloadDirectory);

    public static string? ReadInstallLog()
    {
        try
        {
            if (!File.Exists(InstallLogPath)) return null;
            return string.Join(Environment.NewLine, File.ReadLines(InstallLogPath).TakeLast(12));
        }
        catch
        {
            return null;
        }
    }

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
