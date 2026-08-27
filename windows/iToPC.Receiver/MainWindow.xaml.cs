using Microsoft.Win32;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

namespace iToPC.Receiver;

public partial class MainWindow : Window
{
    private Process? _ffplayProcess;
    private RawFramePump? _framePump;
    private UsbMuxProxy? _usbProxy;
    private CancellationTokenSource? _runCancellation;
    private bool _isStopping;

    private bool IsReceiving => _ffplayProcess is not null || _framePump is not null;

    public MainWindow()
    {
        InitializeComponent();
        FfplayPathBox.Text = FindTool("ffplay.exe") ?? string.Empty;
        AppendLog("1. 仮想カメラを一度インストール");
        AppendLog("2. iPhoneをUSB接続し、iPhone側で［配信開始］");
        AppendLog("3. この画面で［受信開始］");

        if (!VirtualCameraInstaller.IsSupported)
        {
            VirtualCameraCheck.IsChecked = false;
            VirtualCameraCheck.IsEnabled = false;
            VirtualCameraInstallButton.IsEnabled = false;
            VirtualCameraInstallButton.Content = "Windows 11が必要です";
        }
        else
        {
            UpdateVirtualCameraButton();
        }

        Closed += async (_, _) => await StopAsync();
    }

    private void ConnectionModeChanged(object sender, RoutedEventArgs e)
    {
        if (PhoneAddressBox is not null)
        {
            PhoneAddressBox.IsEnabled = WifiModeButton?.IsChecked == true;
        }
    }

    private void BrowseFfplayClicked(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "ffplay.exeまたはffmpeg.exeを選択",
            Filter = "FFmpeg実行ファイル|ffplay.exe;ffmpeg.exe|実行ファイル|*.exe"
        };
        if (dialog.ShowDialog(this) == true)
        {
            var selected = dialog.FileName;
            FfplayPathBox.Text = Path.GetFileName(selected).Equals("ffmpeg.exe", StringComparison.OrdinalIgnoreCase)
                ? Path.Combine(Path.GetDirectoryName(selected)!, "ffplay.exe")
                : selected;
        }
    }

    private async void VirtualCameraInstallClicked(object sender, RoutedEventArgs e)
    {
        if (IsReceiving)
        {
            MessageBox.Show(this, "受信を停止してから仮想カメラを変更してください。", "iToPC Receiver");
            return;
        }

        try
        {
            var payload = FindVirtualCameraPayload();
            VirtualCameraInstallButton.IsEnabled = false;
            StatusText.Text = VirtualCameraInstaller.IsInstalled ? "仮想カメラを削除中" : "仮想カメラをインストール中";

            var exitCode = VirtualCameraInstaller.IsInstalled
                ? await VirtualCameraInstaller.UninstallAsync(payload)
                : await VirtualCameraInstaller.InstallAsync(payload);
            if (exitCode != 0)
            {
                var details = VirtualCameraInstaller.ReadInstallLog();
                if (!string.IsNullOrWhiteSpace(details)) AppendLog(details);
                throw new InvalidOperationException(
                    $"仮想カメラ設定が終了コード{exitCode}で失敗しました。" +
                    (string.IsNullOrWhiteSpace(details) ? string.Empty : $"{Environment.NewLine}{Environment.NewLine}{details}"));
            }

            AppendLog(VirtualCameraInstaller.IsInstalled
                ? "iToPC Cameraをインストールしました。"
                : "iToPC Cameraを削除しました。");
            UpdateVirtualCameraButton();
            StatusText.Text = "停止中";
        }
        catch (Exception error)
        {
            AppendLog("ERROR: " + error.Message);
            MessageBox.Show(this, error.Message, "iToPC Receiver", MessageBoxButton.OK, MessageBoxImage.Error);
            UpdateVirtualCameraButton();
            StatusText.Text = "停止中";
        }
    }

    private async void StartStopClicked(object sender, RoutedEventArgs e)
    {
        if (IsReceiving)
        {
            await StopAsync();
            return;
        }
        await StartAsync();
    }

    private async Task StartAsync()
    {
        try
        {
            var ffplayPath = FfplayPathBox.Text.Trim();
            if (!File.Exists(ffplayPath))
            {
                throw new FileNotFoundException(
                    "ffplay.exeが見つかりません。windows\\scripts\\setup-ffmpeg.ps1を実行するか、参照ボタンで指定してください。",
                    ffplayPath);
            }
            if (!int.TryParse(PortBox.Text, out var devicePort) || devicePort is < 1 or > 65535)
                throw new InvalidOperationException("ポート番号は1〜65535で指定してください。");

            var selectedFps = (FpsBox.SelectedItem as ComboBoxItem)?.Content?.ToString() ?? "120";
            var virtualCameraMode = VirtualCameraCheck.IsChecked == true;
            if (virtualCameraMode && !VirtualCameraInstaller.IsInstalled)
                throw new InvalidOperationException("先に［仮想カメラをインストール］を実行してください。");

            _runCancellation = new CancellationTokenSource();
            string source;
            SetBusy(true, "接続準備中");

            if (UsbModeButton.IsChecked == true)
            {
                AppendLog("USB上のiPhoneを検索しています…");
                _usbProxy = new UsbMuxProxy(devicePort);
                await _usbProxy.StartAsync(_runCancellation.Token);
                source = $"tcp://127.0.0.1:{_usbProxy.LocalPort}";
                AppendLog($"USBトンネルを開きました (localhost:{_usbProxy.LocalPort})");
            }
            else
            {
                var address = PhoneAddressBox.Text.Trim();
                if (string.IsNullOrWhiteSpace(address))
                    throw new InvalidOperationException("iPhoneのIPアドレスを入力してください。");
                source = $"tcp://{address}:{devicePort}";
                AppendLog($"Wi-Fi接続先: {source}");
            }

            if (virtualCameraMode)
            {
                var ffmpegPath = Path.Combine(Path.GetDirectoryName(ffplayPath)!, "ffmpeg.exe");
                if (!File.Exists(ffmpegPath))
                    throw new FileNotFoundException("仮想カメラ出力に必要なffmpeg.exeがffplay.exeと同じフォルダにありません。", ffmpegPath);

                _framePump = new RawFramePump(
                    ffmpegPath,
                    BuildVirtualCameraArguments(selectedFps, source, HardwareDecodeCheck.IsChecked == true),
                    log => Dispatcher.BeginInvoke(() => AppendLog(log)),
                    exitCode => Dispatcher.BeginInvoke(async () =>
                    {
                        if (!_isStopping)
                        {
                            AppendLog($"ffmpegが終了しました (exit {exitCode})。ハードウェアデコードをオフにすると改善する場合があります。");
                            await StopAsync();
                        }
                    }));
                SetBusy(false, "受信中 — iToPC Cameraへ4K120で出力中");
                AppendLog("仮想カメラ出力を開始しました。利用アプリで「iToPC Camera」を選択してください。");
            }
            else
            {
                StartPreview(ffplayPath, selectedFps, source, HardwareDecodeCheck.IsChecked == true);
                SetBusy(false, "受信中 — 映像ウィンドウを開いています");
                AppendLog("低遅延プレビューを開始しました。");
            }

            StartStopButton.Content = "受信停止";
            StartStopButton.Background = new SolidColorBrush(Color.FromRgb(206, 55, 70));
        }
        catch (Exception error)
        {
            AppendLog("ERROR: " + error.Message);
            MessageBox.Show(this, error.Message, "iToPC Receiver", MessageBoxButton.OK, MessageBoxImage.Error);
            await StopAsync();
        }
    }

    private void StartPreview(string ffplayPath, string fps, string source, bool hardwareDecode)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = ffplayPath,
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardError = true
        };
        AddPlayerArguments(startInfo, fps, source, hardwareDecode);

        var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
        process.ErrorDataReceived += (_, args) =>
        {
            if (!string.IsNullOrWhiteSpace(args.Data)) Dispatcher.BeginInvoke(() => AppendLog(args.Data));
        };
        process.Exited += (_, _) => Dispatcher.BeginInvoke(async () =>
        {
            if (!_isStopping)
            {
                AppendLog($"ffplayが終了しました (exit {process.ExitCode})。ハードウェアデコードをオフにすると改善する場合があります。");
                await StopAsync();
            }
        });

        if (!process.Start()) throw new InvalidOperationException("ffplayを起動できませんでした。");
        process.BeginErrorReadLine();
        _ffplayProcess = process;
    }

    private static IEnumerable<string> BuildVirtualCameraArguments(string fps, string source, bool hardwareDecode)
    {
        var arguments = new List<string>
        {
            "-hide_banner", "-loglevel", "warning",
            "-flags", "low_delay", "-avioflags", "direct",
            "-analyzeduration", "0", "-probesize", "4096",
            "-f", "hevc", "-framerate", fps
        };
        if (hardwareDecode)
        {
            arguments.AddRange(["-hwaccel", "d3d11va"]);
        }
        arguments.AddRange(["-i", source, "-an", "-sn", "-dn"]);
        arguments.AddRange(["-vf", "scale=3840:2160:flags=fast_bilinear,fps=120,format=nv12"]);
        arguments.AddRange(["-pix_fmt", "nv12", "-fps_mode", "passthrough", "-flush_packets", "1", "-f", "rawvideo", "pipe:1"]);
        return arguments;
    }

    private static void AddPlayerArguments(ProcessStartInfo info, string fps, string source, bool hardwareDecode)
    {
        string[] commonArguments =
        [
            "-hide_banner", "-loglevel", "warning", "-fflags", "nobuffer",
            "-flags", "low_delay", "-avioflags", "direct", "-analyzeduration", "0",
            "-probesize", "4096", "-framedrop", "-sync", "video", "-f", "hevc", "-framerate", fps
        ];
        foreach (var argument in commonArguments) info.ArgumentList.Add(argument);
        if (hardwareDecode)
        {
            info.ArgumentList.Add("-hwaccel");
            info.ArgumentList.Add("d3d11va");
        }
        info.ArgumentList.Add("-window_title");
        info.ArgumentList.Add("iToPC Camera Preview");
        info.ArgumentList.Add(source);
    }

    private async Task StopAsync()
    {
        if (_isStopping) return;
        _isStopping = true;
        try
        {
            _runCancellation?.Cancel();

            if (_framePump is not null)
            {
                await _framePump.DisposeAsync();
                _framePump = null;
            }
            if (_ffplayProcess is { HasExited: false })
            {
                _ffplayProcess.Kill(entireProcessTree: true);
                try { await _ffplayProcess.WaitForExitAsync(); } catch { }
            }
            _ffplayProcess?.Dispose();
            _ffplayProcess = null;

            if (_usbProxy is not null)
            {
                await _usbProxy.DisposeAsync();
                _usbProxy = null;
            }
            _runCancellation?.Dispose();
            _runCancellation = null;

            StartStopButton.Content = "受信開始";
            StartStopButton.Background = new SolidColorBrush(Color.FromRgb(40, 120, 255));
            SetBusy(false, "停止中");
        }
        finally
        {
            _isStopping = false;
        }
    }

    private void SetBusy(bool busy, string status)
    {
        StatusText.Text = status;
        StartStopButton.IsEnabled = !busy;
        var allowSettings = !busy && !IsReceiving;
        UsbModeButton.IsEnabled = allowSettings;
        WifiModeButton.IsEnabled = allowSettings;
        HardwareDecodeCheck.IsEnabled = allowSettings;
        VirtualCameraCheck.IsEnabled = allowSettings && VirtualCameraInstaller.IsSupported;
        VirtualCameraInstallButton.IsEnabled = allowSettings && VirtualCameraInstaller.IsSupported;
    }

    private void UpdateVirtualCameraButton()
    {
        VirtualCameraInstallButton.Content = VirtualCameraInstaller.IsInstalled
            ? "仮想カメラをアンインストール"
            : "仮想カメラをインストール";
    }

    private void AppendLog(string text)
    {
        LogBox.AppendText($"[{DateTime.Now:HH:mm:ss}] {text}{Environment.NewLine}");
        LogBox.ScrollToEnd();
    }

    private static string FindVirtualCameraPayload()
    {
        var candidates = new[]
        {
            Path.Combine(AppContext.BaseDirectory, "tools", "virtual-camera"),
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "build", "vcam-package"))
        };
        return candidates.FirstOrDefault(path => File.Exists(Path.Combine(path, "install-vcam.ps1")))
            ?? throw new DirectoryNotFoundException("仮想カメラのインストールデータがありません。配布版を再ビルドしてください。");
    }

    private static string? FindTool(string executableName)
    {
        var candidates = new List<string>
        {
            Path.Combine(AppContext.BaseDirectory, "tools", "ffmpeg", executableName),
            Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "..", "tools", "ffmpeg", executableName))
        };
        var path = Environment.GetEnvironmentVariable("PATH") ?? string.Empty;
        candidates.AddRange(path.Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(folder => Path.Combine(folder.Trim('"'), executableName)));
        return candidates.FirstOrDefault(File.Exists);
    }
}
