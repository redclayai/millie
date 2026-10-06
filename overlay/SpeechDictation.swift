import Foundation
import Speech
import AVFoundation
import Combine

/// On-device speech-to-text for the launcher's mic button. Streams a live
/// partial transcript while listening so the launcher can mirror it into the
/// search field as the user speaks, then finalizes on stop.
///
/// macOS has no `AVAudioSession` (that's iOS); we drive an `AVAudioEngine`
/// input tap straight into an `SFSpeechAudioBufferRecognitionRequest`. Every
/// permission / availability failure resolves to a brief `unavailable` flag
/// instead of a crash, so a denied mic or missing recognizer just no-ops.
@MainActor
final class SpeechDictation: ObservableObject {
    /// True while the mic is live and partial results are streaming.
    @Published private(set) var isListening = false
    /// Latest (partial or final) transcript for the current session.
    @Published private(set) var transcript = ""
    /// Briefly true when dictation can't start (denied / unsupported / no mic),
    /// so the UI can flash an unavailable state without a persistent error.
    @Published private(set) var unavailable = false

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var unavailableReset: Task<Void, Never>?

    func toggle() {
        isListening ? stop() : start()
    }

    func start() {
        guard !isListening else { return }
        guard let recognizer, recognizer.isAvailable else { flagUnavailable(); return }

        // Both callbacks arrive off the main thread; hop back to the MainActor
        // before touching any state.
        SFSpeechRecognizer.requestAuthorization { status in
            guard status == .authorized else {
                Task { @MainActor [weak self] in self?.flagUnavailable() }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { micGranted in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    micGranted ? self.beginSession() : self.flagUnavailable()
                }
            }
        }
    }

    /// Stop listening, finalize the audio, and tear the engine down. Idempotent
    /// and safe to call from the launcher's dismiss path.
    func stop() {
        isListening = false
        request?.endAudio()
        task?.cancel()
        task = nil
        request = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    // MARK: - Internals

    private func beginSession() {
        guard let recognizer else { flagUnavailable(); return }
        // Clear any stale tap/engine before (re)starting.
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        // A zero-channel format means no usable input device — bail cleanly.
        guard format.channelCount > 0 else { self.request = nil; flagUnavailable(); return }

        // Capture the request locally (not self) so the audio-thread tap never
        // touches main-actor state.
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            audioEngine.inputNode.removeTap(onBus: 0)
            self.request = nil
            flagUnavailable()
            return
        }

        transcript = ""
        isListening = true

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                }
                if error != nil || (result?.isFinal ?? false) {
                    self.stop()
                }
            }
        }
    }

    private func flagUnavailable() {
        isListening = false
        unavailable = true
        unavailableReset?.cancel()
        unavailableReset = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.unavailable = false
        }
    }
}
