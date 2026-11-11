# Libraries, Toolkits, and Frameworks

Lecture Me Faster has no third-party dependencies. Everything below ships with Apple's SDKs or is a
network service the app talks to over plain HTTP.

## Apple frameworks

| Framework | Used in | What for |
|---|---|---|
| SwiftUI | `MyApp.swift`, `Frontend/` | All UI |
| Observation | `Frontend/AppSettings.swift`, `Frontend/LectureSession.swift` | `@Observable` app state |
| AVFoundation | `Backend/VideoToFrames.swift`, `Backend/AudioToTranscription.swift` | Reading video, sampling frames (`AVAssetImageGenerator`), splitting out the audio track (`AVAssetExportSession`), reading audio (`AVAudioFile`) |
| Speech | `Backend/AudioToTranscription.swift` | On-device transcription (`SpeechAnalyzer`, `SpeechTranscriber`, `AssetInventory`) |
| CoreGraphics | `Backend/VideoToFrames.swift` | Downscaling frames to compare them for slide changes |
| ImageIO | `Backend/VideoToFrames.swift`, `Frontend/LectureResultView.swift` | JPEG encoding and decoding of frames |
| UniformTypeIdentifiers | `Backend/VideoToFrames.swift`, `Frontend/ContentView.swift` | File types for the importer and JPEG output |
| Foundation | everywhere | `URLSession` networking and streaming, JSON, `UserDefaults` |
| Security | `Frontend/AppSettings.swift` | Storing API keys in the Keychain |
| Swift Testing | `Lecture Me FasterTests/` | Unit tests (test target only, not shipped in the app) |

## AI services (called over HTTP from `Backend/FileToAI.swift`, no SDKs)

| Service | Endpoint | Notes |
|---|---|---|
| Ollama | `POST /api/chat`, `GET /api/tags` | Local models, free. Default server `http://localhost:11434` |
| Claude (Anthropic API) | `POST https://api.anthropic.com/v1/messages` | Paid, needs an API key. Streaming Messages API |
| OpenAI-compatible servers | `POST {base URL}/chat/completions` | LM Studio, llama.cpp, OpenRouter, and similar |

## Tooling

- Xcode 27.2, Swift 6.4 toolchain (Swift 5 language mode, main-actor default isolation)
- Targets: macOS, iOS, and visionOS 27.2
