import Foundation

public enum Command {
    case record(RecordingSession.Config)
    case finalizePending
    case ingestPending
    case listDisplays
    case sessions(query: String?, wikiRoot: String?)
    case cleanAudio(days: Int)
    case help
}

public struct CLI {
    public static func printHelp() {
        print("""
LocalTranscriber: Private macOS audio capture & local Whisper transcription tool.

USAGE:
  swift run LocalTranscriber <command> [options]

QUICK SHORTCUTS:
  swift run LocalTranscriber record en             # Record directly in English
  swift run LocalTranscriber record hi             # Record directly in Hindi
  swift run LocalTranscriber record mr             # Record directly in Marathi
  swift run LocalTranscriber record en --title "Team Sync"

COMMANDS:
  record [lang]     Start recording microphone and system audio
  finalize-pending  Run deferred final-pass transcription jobs
  ingest-pending    Replay queued /ingest commands in Terminal
  list-displays     List available displays and indices for audio capture
  sessions          List or search past transcription sessions
  clean-audio       Prune preserved audio folders older than specified days
  help              Show this help text

RECORD OPTIONS:
  --title <text>           Session title (default: "Call Session")
  --language <lang>        Audio language: auto, en, hi, mr (default: auto)
  --task <task>            Whisper task: transcribe or translate (default: transcribe)
  --speaker-labels         Include [You] and [Remote / System] attribution tags
  --wiki-root <path>       Target LLM wiki root directory
  --no-wiki                Save to Application Support instead of LLM wiki
  --keep-audio             Preserve WAV files on disk after transcription
  --live-only              Skip authoritative final pass and file live transcript
  --auto-ingest            Automatically launch Terminal with /ingest on completion
  --display <N>            Display index to capture audio from (default: 0)

SESSIONS OPTIONS:
  --query <text>           Filter sessions by title, filename, or transcript snippet

CLEAN-AUDIO OPTIONS:
  --days <N>               Delete preserved audio folders older than N days (default: 14)

ENVIRONMENT OVERRIDES:
  LOCAL_TRANSCRIBER_MODEL         Live chunk model (default: mlx-community/whisper-large-v3-turbo)
  LOCAL_TRANSCRIBER_FINAL_MODEL   Final pass model (default: mlx-community/whisper-large-v3)
  LOCAL_TRANSCRIBER_WIKI_ROOT     Default wiki directory
  LOCAL_TRANSCRIBER_FAKE          Set to 1 to run with simulated responses
  LOCAL_TRANSCRIBER_CHUNK_TIMEOUT Chunk timeout in seconds (default: 90)
  LOCAL_TRANSCRIBER_FINAL_TIMEOUT Final pass timeout in seconds (default: 1200)
  LOCAL_TRANSCRIBER_STALL_SECONDS Audio stall watchdog timeout (default: 10)
""")
    }

    public static func parse(arguments: [String]) -> Command {
        // Drop executable path
        let args = Array(arguments.dropFirst())

        guard let first = args.first else {
            return .help
        }

        switch first {
        case "help", "--help", "-h":
            return .help

        case "finalize-pending":
            return .finalizePending

        case "ingest-pending":
            return .ingestPending

        case "list-displays":
            return .listDisplays

        case "clean-audio":
            var days = 14
            var i = 1
            while i < args.count {
                if args[i] == "--days", i + 1 < args.count {
                    days = Int(args[i + 1]) ?? 14
                    i += 1
                }
                i += 1
            }
            return .cleanAudio(days: days)

        case "sessions":
            var query: String? = nil
            var wikiRoot: String? = nil
            var i = 1
            while i < args.count {
                if args[i] == "--query", i + 1 < args.count {
                    query = args[i + 1]
                    i += 1
                } else if args[i] == "--wiki-root", i + 1 < args.count {
                    wikiRoot = args[i + 1]
                    i += 1
                }
                i += 1
            }
            return .sessions(query: query, wikiRoot: wikiRoot)

        case "record":
            var title = "Call Session"
            var language = "auto"
            var task = "transcribe"
            var includeSpeakerLabels = false
            var wikiRoot: String? = nil
            var noWiki = false
            var keepAudio = false
            var liveOnly = false
            var autoIngest = false
            var displayIndex = 0

            let knownLanguages: Set<String> = ["auto", "en", "hi", "mr"]

            var i = 1
            while i < args.count {
                let arg = args[i]
                switch arg {
                case "--title":
                    if i + 1 < args.count {
                        title = args[i + 1]
                        i += 1
                    }
                case "--language":
                    if i + 1 < args.count {
                        language = args[i + 1]
                        i += 1
                    }
                case "--task":
                    if i + 1 < args.count {
                        task = args[i + 1]
                        i += 1
                    }
                case "--speaker-labels":
                    includeSpeakerLabels = true
                case "--wiki-root":
                    if i + 1 < args.count {
                        wikiRoot = args[i + 1]
                        i += 1
                    }
                case "--no-wiki":
                    noWiki = true
                case "--keep-audio":
                    keepAudio = true
                case "--live-only":
                    liveOnly = true
                case "--auto-ingest":
                    autoIngest = true
                case "--display":
                    if i + 1 < args.count {
                        displayIndex = Int(args[i + 1]) ?? 0
                        i += 1
                    }
                default:
                    if knownLanguages.contains(arg.lowercased()) {
                        language = arg.lowercased()
                    } else if !arg.hasPrefix("-") && title == "Call Session" {
                        title = arg
                    }
                }
                i += 1
            }

            let config = RecordingSession.Config(
                title: title,
                language: language,
                task: task,
                includeSpeakerLabels: includeSpeakerLabels,
                customWikiRoot: wikiRoot,
                forceNoWiki: noWiki,
                keepAudio: keepAudio,
                liveOnly: liveOnly,
                autoIngest: autoIngest,
                displayIndex: displayIndex
            )
            return .record(config)

        default:
            return .help
        }
    }
}
