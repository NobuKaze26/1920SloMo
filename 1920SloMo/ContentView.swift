import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @State private var camera = CameraManager()
    @State private var watchRemote = WatchRemoteManager()

    var body: some View {
        CameraView(camera: camera)
            .task {
                watchRemote.activate(
                    toggleRecording: {
                        if camera.isRecording {
                            camera.stopRecording()
                        } else {
                            await camera.startRecording()
                        }
                    },
                    recordingState: {
                        (isRecording: camera.isRecording, isReady: camera.isConfigured)
                    }
                )
                watchRemote.setApplicationActive(scenePhase == .active)
            }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    watchRemote.publish()
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                watchRemote.setApplicationActive(phase == .active)
            }
            .onChange(of: camera.isConfigured) {
                watchRemote.publish()
            }
            .onChange(of: camera.isRecording) {
                watchRemote.publish()
            }
            .onDisappear {
                watchRemote.setApplicationActive(false)
            }
    }
}

#Preview {
    ContentView()
}
