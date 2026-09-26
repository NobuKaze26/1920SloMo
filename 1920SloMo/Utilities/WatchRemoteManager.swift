@preconcurrency import WatchConnectivity
import Foundation

@MainActor
final class WatchRemoteManager: NSObject, WCSessionDelegate {
    typealias RecordingState = (isRecording: Bool, isReady: Bool)

    var toggleRecording: (() async -> Void)?
    var recordingState: (() -> RecordingState)?

    private var session: WCSession?
    private var isApplicationActive = false

    func activate(
        toggleRecording: @escaping () async -> Void,
        recordingState: @escaping () -> RecordingState
    ) {
        self.toggleRecording = toggleRecording
        self.recordingState = recordingState

        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        self.session = session
    }

    func setApplicationActive(_ isActive: Bool) {
        isApplicationActive = isActive
        publish()
    }

    func publish() {
        guard let session, session.activationState == .activated else { return }
        let state = currentState()
        try? session.updateApplicationContext(state)
        guard session.isReachable else { return }
        session.sendMessage(state, replyHandler: nil, errorHandler: { _ in })
    }

    private func currentState() -> [String: Any] {
        let state = recordingState?() ?? (isRecording: false, isReady: false)
        return [
            "isRecording": isApplicationActive && state.isRecording,
            "isReady": isApplicationActive && state.isReady,
            "isAppActive": isApplicationActive,
            "sentAt": Date().timeIntervalSince1970
        ]
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor [weak self] in
            guard
                let self,
                message["action"] as? String == "toggleRecording",
                self.isApplicationActive,
                self.recordingState?().isReady == true
            else {
                return
            }
            await self.toggleRecording?()
            self.publish()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else {
                replyHandler([
                    "isRecording": false,
                    "isReady": false,
                    "isAppActive": false,
                    "sentAt": Date().timeIntervalSince1970
                ])
                return
            }

            if message["action"] as? String == "toggleRecording",
               self.isApplicationActive,
               self.recordingState?().isReady == true {
                await self.toggleRecording?()
            }

            replyHandler(self.currentState())
        }
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated, error == nil else { return }
        Task { @MainActor [weak self] in
            self?.publish()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.activationState == .activated, session.isReachable else { return }
        Task { @MainActor [weak self] in
            self?.publish()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        guard session.activationState == .activated, session.isWatchAppInstalled else { return }
        Task { @MainActor [weak self] in
            self?.publish()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
