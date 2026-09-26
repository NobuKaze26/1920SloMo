import AVKit
import SwiftUI

struct RecordingReviewView: View {
    let result: RecordingResult
    let dismiss: () -> Void
    @State private var player: AVPlayer

    init(result: RecordingResult, dismiss: @escaping () -> Void) {
        self.result = result
        self.dismiss = dismiss
        _player = State(initialValue: AVPlayer(url: result.processedURL))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ResponsiveAppBackground()
                VStack(spacing: 18) {
                    VideoPlayer(player: player)
                        .aspectRatio(result.displayAspectRatio, contentMode: .fit)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                    VStack(spacing: 6) {
                        Text("REAL CAPTURE")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text("\(result.capturedFPS) FPS")
                            .font(.title2.bold())
                        Text("Slow motion: \(result.equivalentFPS / result.playbackFPS)× at \(result.playbackFPS) FPS playback")
                            .font(.subheadline)
                    }
                    Text("Saved to \(result.saveDestinationName)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Recording")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: dismiss)
                }
            }
            .onAppear { player.play() }
            .onDisappear { player.pause() }
        }
    }
}
