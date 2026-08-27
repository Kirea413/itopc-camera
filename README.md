# iToPC

iPhoneの背面カメラを、USB優先でWindows PCへ低遅延転送するアプリです。対応するiPhoneでは4K/120fpsを要求し、実機が対応しない場合は4K/60以下へ自動的にフォールバックします。Windowsでは `iToPC Camera` という仮想カメラとしてZoom、Teams、OBS、Discord、ブラウザなどから選択できます。

「遅延ゼロ」は実現できません。この構成は、映像取得、HEVCエンコード、USB転送、GPUデコード、画面更新に必要な時間だけ遅延します。最初の実機目標はUSB接続でおおむね30〜80msですが、端末、GPU、ケーブル、ディスプレイによって変わります。

## 構成

- `ios/`: SwiftUI + AVFoundation + VideoToolboxのiPhoneアプリ
- `windows/`: .NET 8 WPFのWindows受信アプリ
- `windows/iToPC.VirtualCamera.Source/`: Windows Media Foundation仮想カメラ
- `docs/ARCHITECTURE.md`: 転送経路、低遅延設定、制限事項

## 必要環境

- iPhone: iOS 16以降。4K/120対応可否は起動時に実機判定
- Windows: 仮想カメラはWindows 11 build 22000以降
- USB接続: Apple Mobile Deviceサービスと信頼済みiPhone
- GPU: HEVCハードウェアデコード対応を推奨

## 1. Windows受信アプリを作る

PowerShellで次を実行します。

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\windows\scripts\build-receiver.ps1
```

初回はFFmpegのWindows向け静的ビルドを取得し、受信EXE、仮想カメラのNative AOT DLL、制御EXEを生成します。完成した実行ファイルは `windows\dist\iToPC-Receiver-win-x64\iToPC.Receiver.exe` に出力されます。

USB接続にはApple Mobile Deviceサービスが必要です。SideloadlyのUSBドライバーで検出できない場合は、Apple DevicesまたはiTunesをインストールし、iPhoneのロックを解除して「このコンピュータを信頼」を許可してください。

## 2. 未署名IPAを作る

### macOSを使う場合

XcodeとXcodeGenを入れたMacで実行します。

```bash
brew install xcodegen
chmod +x ios/build-ipa.sh
ios/build-ipa.sh
```

`ios/build/iToPC-unsigned.ipa` が作成されます。

### GitHub Actionsを使う場合

このフォルダをGitHubリポジトリへpushし、Actionsの `Build unsigned iOS IPA` を実行します。完了後、`iToPC-unsigned-ipa` artifactをダウンロードします。

## 3. Sideloadlyで導入する

1. Sideloadlyで `iToPC-unsigned.ipa` を選択する。
2. USB接続したiPhoneへ署名・インストールする。
3. 初回起動時にカメラとローカルネットワークを許可する。

## 4. 仮想カメラをインストールする

Windowsの `iToPC.Receiver.exe` を起動し、`仮想カメラをインストール` を押します。UAC確認を許可すると、Media FoundationソースがProgram Filesへ登録されます。これは最初の一度だけ必要です。

アンインストールする場合は、同じボタンが `仮想カメラをアンインストール` に変わるので、カメラを利用中のアプリを閉じてから実行します。

## 5. USBで使う

1. iPhoneをWindows PCへUSB接続し、ロックを解除する。
2. iPhoneのiToPCに実機カメラが対応する画質だけが表示されるので、画質を選び `配信開始` を押す。
3. Windowsの `iToPC.Receiver.exe` を起動する。
4. `USB（推奨）`、iPhoneと同じFPS、`D3D11VA`、`iToPC Cameraへ出力`を選んで `受信開始` を押す。
5. ZoomやOBSなどのカメラ一覧で `iToPC Camera` を選ぶ。

iPhone→PC間と仮想カメラ出力は最大3840×2160/120fpsです。仮想カメラは4K/120fps NV12として公開されます。入力が4K/120未満の場合も公開形式は4K/120のままですが、受信側ではフレームを水増しせず常に最新フレームだけを共有します。実際のディテールと時間解像度はiPhone側で選ばれた形式が上限です。

4K/120の仮想カメラは約1.49GB/sの非圧縮フレーム帯域を使います。利用先アプリが4K/120のカメラ入力に対応しない場合は映像が開けないことがあります。また、旧1080p/60版の仮想カメラをインストール済みの場合は、受信アプリから一度アンインストールし、新しい配布版でもう一度インストールしてください。

仮想カメラの公開形式は4K/120fpsですが、現行のCPU共有メモリ経路ではPCのメモリ帯域や利用先アプリによって実効fpsが下がります。iPhone側はエンコーダーへ投入する未完了フレームを最大1枚に制限し、VideoToolboxの最大フレーム遅延を可能なら0へ設定します。転送はフレーム境界付きで、iPhone側またはPC側が詰まると古いGOPを捨てて次のキーフレームから再開し、遅延が時間とともに増え続けるのを防ぎます。

FFmpegがデコードした4K NV12映像は、1MiBバッファのWindows名前付きパイプから共有メモリへ直接読み込みます。仮想カメラのMedia Foundationサンプルプールは3枚に制限し、映像スレッド内での強制GCは行いません。

仮想カメラのインストールに失敗した場合は、受信アプリのログに `%ProgramData%\iToPC\virtual-camera-install.log` の末尾が表示されます。修正版インストーラーは更新中だけWindows Camera Frame Serverを停止し、DLLの置き換え後に自動で再起動します。

映像が出ずffmpegまたはffplayが終了する場合は、Windows側の `D3D11VA ハードウェアデコード` をオフにして確認します。ただし、ソフトウェアデコードで4K/120を維持するのは非常に困難です。

## 6. Wi-Fiで使う

iPhone画面に表示されるIPアドレスをWindowsへ入力し、接続方式を `Wi-Fi` にします。Windows Defender Firewallの確認が出た場合は、プライベートネットワークだけを許可します。4K/120ではUSBよりパケット詰まりと遅延が起きやすくなります。

## ライセンス上の注意

セットアップスクリプトが取得するffplayはFFmpeg-BuildsのGPL版です。個人利用を越えて受信アプリと一緒に再配布する場合は、同梱ライセンスとFFmpegのGPL要件を確認してください。

Media Foundation仮想カメラソースは、Simon Mourier氏のVCamNetSample（MIT）を基に変更しています。原ライセンスは `THIRD_PARTY_LICENSES/VCamNetSample-MIT.txt` とWindows配布物に同梱しています。
