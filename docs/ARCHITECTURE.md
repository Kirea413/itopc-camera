# iToPC 技術設計

## データ経路

```text
iPhone camera
  → AVCaptureVideoDataOutput (NV12)
  → VideoToolbox hardware HEVC encoder
  → HEVC Annex-B byte stream
  → NWListener TCP :5000
  → Apple usbmux / USB cable
  → local TCP proxy in iToPC Receiver
  → FFmpeg + D3D11VA
  → 3840×2160/120 NV12 double-buffered frame file
  → Media Foundation virtual camera source
  → Zoom / Teams / OBS / browser
```

Wi-Fiモードではusbmuxを通さず、WindowsからiPhoneのローカルIPアドレスのTCP 5000番へ直接接続する。

## 遅延を抑える設定

- カメラ出力は `alwaysDiscardsLateVideoFrames = true`。
- HEVCはVideoToolboxのリアルタイム・ハードウェアエンコードを必須にする。
- Bフレームを無効化し、キーフレーム間隔を1秒にする。
- TCP_NODELAYを有効化する。
- 送信待ちを最大3フレームに制限する。
- 詰まりを検出した場合は古い依存フレームを捨て、強制キーフレームから再開する。
- WindowsはFFmpegの解析時間と同期バッファを最小化する。
- 仮想カメラは最新フレームだけを読む二重バッファで、読み手が遅れても受信側を停止させない。

## 映像形式

映像は長さ付きHEVC NALをiPhone上でAnnex-Bへ変換する。各キーフレームの直前にVPS、SPS、PPSを再送し、キーフレーム間隔は約0.5秒。音声とコンテナは使わない。これは映像遅延を最小化するための意図的な制限。

仮想カメラ用共有ファイルは `%ProgramData%\iToPC\frames.nv12`。4096バイトのヘッダーに形式、アクティブスロット、シーケンス番号を置き、その後ろに3840×2160 NV12フレームを2枚保持する。受信側は未使用スロットへ書いてからアクティブスロットを原子的に切り替え、Media Foundationソースは読み込み前後のシーケンスが一致するフレームだけを公開する。1フレームは12,441,600バイト、120fps時の生フレーム帯域は約1.49GB/s。

## 4K/120の条件

起動時に実機の `AVCaptureDevice.Format` を照会し、4K/120を本当に提供する組み合わせだけを選ぶ。利用できない場合は、4K/60、4K/30、1080p/120、1080p/60の順で自動的に落とす。実際に選ばれた解像度とfpsはiPhone画面に表示する。

4K/120を維持するには、iPhoneのカメラとVideoToolbox、USB経路、Windows GPUのHEVCデコーダ、表示側のリフレッシュレートの全てが追従する必要がある。発熱時のiOS側クロック制限もあるため、固定保証はできない。

## 現在の制限

- 映像のみ。音声転送は未実装。
- 仮想カメラ出力は3840×2160/120fps NV12固定。利用先アプリがこのカメラ形式に対応しない場合がある。
- 仮想カメラを無効にしたプレビューは、受信アプリ内ではなくffplayの別ウィンドウに表示する。
- Media Foundation仮想カメラAPIのためWindows 11 build 22000以降が必要。
- USB接続にはApple Mobile Deviceサービスと、iPhone側での「このコンピュータを信頼」が必要。
- 実機がない自動テストでは、iOSのカメラ形式・VideoToolbox・USB接続を検証できない。
