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

                Picker("画質", selection: $preset) {
                    ForEach(StreamPreset.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(streamer.isRunning)

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
                }
            }
            .padding(18)
        }
        .alert("iToPC", isPresented: $streamer.isShowingError) {
            Button("閉じる", role: .cancel) {}
        } message: {
            Text(streamer.errorText ?? "不明なエラー")
        }
    }
}

