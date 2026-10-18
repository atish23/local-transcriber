import Foundation
import ScreenCaptureKit

@main
struct LocalTranscriber {
    static func main() async {
        let command = CLI.parse(arguments: CommandLine.arguments)

        switch command {
        case .help:
            CLI.printHelp()

        case .listDisplays:
            do {
                let displays = try await CaptureEngine.getAvailableDisplays()
                print("\nAvailable Displays for Audio Capture:")
                for (index, display) in displays.enumerated() {
                    print("  [\(index)] Display ID: \(display.displayID) (Width: \(display.width), Height: \(display.height))")
                }
                print("\nUse '--display <index>' with the record command.\n")
            } catch {
                print("Failed to enumerate displays: \(error.localizedDescription)")
            }

        case .finalizePending:
            do {
                try await PendingFinalPassQueue.processAll()
            } catch {
                print("Error during finalize-pending: \(error.localizedDescription)")
            }

        case .ingestPending:
            IngestLauncher.processPending()

        case .sessions(let query, let wikiRoot):
            SessionsCommand.run(query: query, customWikiRoot: wikiRoot)

        case .cleanAudio(let days):
            AudioRetention.cleanAudio(olderThanDays: days)

        case .record(let config):
            // Check macOS permissions
            let status = await CaptureEngine.checkPermissions()
            switch status {
            case .microphoneDenied:
                print("\n[PERMISSION ERROR] Microphone access is required to record audio.")
                print("Please enable LocalTranscriber under:")
                print("  System Settings -> Privacy & Security -> Microphone\n")
                exit(1)

            case .screenDenied:
                print("\n[PERMISSION ERROR] Screen Recording access is required to capture system audio.")
                print("Please enable LocalTranscriber under:")
                print("  System Settings -> Privacy & Security -> Screen Recording\n")
                exit(1)

            case .authorized:
                break
            }

            do {
                let session = try RecordingSession(config: config)
                try await session.start()
            } catch {
                print("\n[SESSION ERROR] \(error.localizedDescription)")
                exit(1)
            }
        }
    }
}
