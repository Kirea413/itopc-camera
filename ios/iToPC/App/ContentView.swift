import SwiftUI

struct ContentView: View {
    @StateObject private var streamer = CameraStreamer()
    @State private var preset = StreamPreset.ultra

    var body: some View {
        ZStack(alignment: .bottom) {
            CameraPreview(session: streamer.captureSession)
                .ignoresSafeArea()

            LinearGradient(
                colors: [.clear, .black.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 14) {
                HStack {
                    Circle()
                        .fill(streamer.isClientConnected ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(streamer.statusText)
                        .font(.subheadline.monospaced())
                    Spacer()
                    if let actual = streamer.actualFormatText {
                        Text(actual)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if streamer.isDetectingPresets {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("このiPhoneの対応画質を確認中…")
                            .font(.subheadline)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else if streamer.supportedPresets.isEmpty {
                    Text("このカメラで利用できる配信形式がありません")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Picker("画質", selection: $preset) {
                        ForEach(streamer.supportedPresets) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(streamer.isRunning)
                }

                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("USB: Apple Mobile Device経由")
                        Text("Wi-Fi: \(streamer.wifiAddress):5000")
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)

                    Spacer()

                    Button {
                        if streamer.isRunning {
                            streamer.stop()
                        } else {
                            streamer.start(preset: preset)
                        }
                    } label: {
                        Text(streamer.isRunning ? "停止" : "配信開始")
                            .fontWeight(.semibold)
                            .frame(minWidth: 86)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(streamer.isRunning ? .red : .blue)
                    .disabled(streamer.isDetectingPresets || streamer.supportedPresets.isEmpty)
                }
            }
            .padding(18)
        }
        .alert("iToPC", isPresented: $streamer.isShowingError) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(streamer.errorText ?? "不明なエラー")
        }
        .onChange(of: streamer.supportedPresets) { presets in
            guard let first = presets.first else { return }
            if !presets.contains(preset) {
                preset = first
            }
        }
    }
}
