import Observation
import SwiftUI
@preconcurrency import WatchConnectivity

@MainActor
@Observable
final class WatchRecordingRemote: NSObject, WCSessionDelegate {
    var isRecording = false
    var isConnected = false
    var isPhoneReady = false

    private let session = WCSession.default
    private var isPhoneActive = false
    private var lastUpdate: Date?
    private var freshnessTask: Task<Void, Never>?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        session.delegate = self
        session.activate()
        apply(session.receivedApplicationContext)
    }


    func resume() {
        guard WCSession.isSupported() else { return }
        requestPhoneStatus()
    }

    func suspend() {
        disconnect()
    }

    func toggleRecording() {
        guard isConnected, isPhoneReady else { return }
        session.sendMessage(
            ["action": "toggleRecording"],
            replyHandler: { [weak self] values in
                Task { @MainActor in
                    self?.apply(values)
                }
            },
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.disconnect()
                }
            }
        )
    }

    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard activationState == .activated, error == nil else {
                self?.disconnect()
                return
            }
            self?.apply(session.receivedApplicationContext)
            self?.requestPhoneStatus()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            guard session.isReachable else {
                self?.disconnect()
                return
            }
            self?.requestPhoneStatus()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor [weak self] in
            self?.apply(applicationContext)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor [weak self] in
            self?.apply(message)
        }
    }

    private func requestPhoneStatus() {
        guard session.activationState == .activated, session.isReachable else {
            disconnect()
            return
        }

        session.sendMessage(
            ["action": "status"],
            replyHandler: { [weak self] values in
                Task { @MainActor in
                    self?.apply(values)
                }
            },
            errorHandler: { [weak self] _ in
                Task { @MainActor in
                    self?.disconnect()
                }
            }
        )
    }

    private func apply(_ values: [String: Any]) {
        guard
            let sentAt = values["sentAt"] as? TimeInterval,
            Date().timeIntervalSince1970 - sentAt < 3,
            values["isAppActive"] as? Bool == true
        else {
            disconnect()
            return
        }

        isPhoneActive = true
        lastUpdate = Date()
        isRecording = values["isRecording"] as? Bool ?? false
        isPhoneReady = values["isReady"] as? Bool ?? false
        isConnected = session.activationState == .activated && session.isReachable

        freshnessTask?.cancel()
        freshnessTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.expireStaleConnection()
        }
    }

    private func expireStaleConnection() {
        guard let lastUpdate, Date().timeIntervalSince(lastUpdate) >= 3 else { return }
        disconnect()
    }

    private func disconnect() {
        freshnessTask?.cancel()
        freshnessTask = nil
        lastUpdate = nil
        isPhoneActive = false
        isConnected = false
        isPhoneReady = false
        isRecording = false
    }
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var remote = WatchRecordingRemote()

    var body: some View {
        VStack(spacing: 12) {
            Text(connectionLabel)
                .font(.headline)
                .foregroundStyle(remote.isConnected ? (remote.isPhoneReady ? .green : .yellow) : .secondary)

            Spacer()

            Button(action: remote.toggleRecording) {
                VStack(spacing: 6) {
                    Image(systemName: remote.isRecording ? "stop.fill" : "record.circle")
                        .font(.system(size: 42, weight: .bold))
                    Text(remote.isRecording ? "Stop" : "Record")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(!remote.isConnected || !remote.isPhoneReady)
        }
        .padding()
        .onAppear {
            remote.resume()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                remote.resume()
            } else if phase == .background {
                remote.suspend()
            }
        }
    }

    private var connectionLabel: String {
        if !remote.isConnected { return "NOT CONNECTED" }
        return remote.isPhoneReady ? "CONNECTED" : "PHONE NOT READY"
    }
}

#Preview {
    ContentView()
}
