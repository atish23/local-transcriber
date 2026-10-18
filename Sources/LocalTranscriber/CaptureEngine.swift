import Foundation
import ScreenCaptureKit
import AVFoundation

public enum CapturePermissionStatus {
    case authorized
    case microphoneDenied
    case screenDenied
}

public protocol CaptureEngineDelegate: AnyObject {
    func captureEngine(_ engine: CaptureEngine, didReceiveMicBuffer buffer: CMSampleBuffer)
    func captureEngine(_ engine: CaptureEngine, didReceiveDeviceBuffer buffer: CMSampleBuffer)
    func captureEngineDidStall(_ engine: CaptureEngine)
    func captureEngine(_ engine: CaptureEngine, didFailWithError error: Error)
}

public final class CaptureEngine: NSObject, SCStreamOutput, SCStreamDelegate {
    public weak var delegate: CaptureEngineDelegate?

    private var stream: SCStream?
    private let processingQueue = DispatchQueue(label: "local.atish.LocalTranscriber.capture", qos: .userInitiated)
    private var lastAudioReceivedTime: Date = Date()
    private var watchdogTimer: DispatchSourceTimer?
    private var reconnectAttempts = 0
    private var isRunning = false
    private let selectedDisplayIndex: Int

    public var stallSeconds: TimeInterval = {
        if let env = ProcessInfo.processInfo.environment["LOCAL_TRANSCRIBER_STALL_SECONDS"],
           let val = TimeInterval(env) {
            return val
        }
        return 10.0
    }()

    public var maxReconnectAttempts: Int = {
        if let env = ProcessInfo.processInfo.environment["LOCAL_TRANSCRIBER_RECONNECT_ATTEMPTS"],
           let val = Int(env) {
            return val
        }
        return 5
    }()

    public init(displayIndex: Int = 0) {
        self.selectedDisplayIndex = displayIndex
        super.init()
    }

    public static func checkPermissions() async -> CapturePermissionStatus {
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if micStatus == .denied || micStatus == .restricted {
            return .microphoneDenied
        }

        if micStatus == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                return .microphoneDenied
            }
        }

        let screenAccess = CGPreflightScreenCaptureAccess()
        if !screenAccess {
            CGRequestScreenCaptureAccess()
            return .screenDenied
        }

        return .authorized
    }

    public static func getAvailableDisplays() async throws -> [SCDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        return content.displays
    }

    public func start() async throws {
        let displays = try await Self.getAvailableDisplays()
        guard !displays.isEmpty else {
            throw NSError(domain: "CaptureEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "No displays found for audio capture"])
        }

        let display = (selectedDisplayIndex < displays.count) ? displays[selectedDisplayIndex] : displays[0]
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.width = 64
        config.height = 64
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: processingQueue)
        try newStream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: processingQueue)

        self.stream = newStream
        try await newStream.startCapture()
        self.isRunning = true
        self.lastAudioReceivedTime = Date()
        self.reconnectAttempts = 0

        startWatchdog()
    }

    public func stop() async {
        isRunning = false
        stopWatchdog()
        if let stream = stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
    }

    private func startWatchdog() {
        stopWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: processingQueue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.isRunning else { return }
            let elapsed = Date().timeIntervalSince(self.lastAudioReceivedTime)
            if elapsed > self.stallSeconds {
                self.delegate?.captureEngineDidStall(self)
                // Reset so stall notification is periodic rather than flooding every second
                self.lastAudioReceivedTime = Date()
            }
        }
        timer.resume()
        self.watchdogTimer = timer
    }

    private func stopWatchdog() {
        watchdogTimer?.cancel()
        watchdogTimer = nil
    }

    // MARK: - SCStreamOutput
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid, isRunning else { return }

        lastAudioReceivedTime = Date()

        switch type {
        case .microphone:
            delegate?.captureEngine(self, didReceiveMicBuffer: sampleBuffer)
        case .audio:
            delegate?.captureEngine(self, didReceiveDeviceBuffer: sampleBuffer)
        default:
            break
        }
    }

    // MARK: - SCStreamDelegate
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard isRunning else { return }

        if reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            let delaySeconds = Double(reconnectAttempts)
            processingQueue.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
                guard let self = self, self.isRunning else { return }
                Task {
                    do {
                        try await self.start()
                    } catch {
                        self.delegate?.captureEngine(self, didFailWithError: error)
                    }
                }
            }
        } else {
            delegate?.captureEngine(self, didFailWithError: error)
        }
    }
}
