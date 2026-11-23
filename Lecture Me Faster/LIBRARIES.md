
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
| ImageIO | `Backend/VideoToFrames.swift`, `Backend/Documents/DocumentToText.swift`, `Frontend/LectureResultView.swift` | JPEG encoding and decoding of frames; loading image files for text recognition |
| Observation | `Backend/History/LectureHistory.swift` | `@Observable` history and Recently Deleted lists |
| UniformTypeIdentifiers | `Backend/VideoToFrames.swift`, `Frontend/ContentView.swift` | File types for the importer and JPEG output |
| Foundation | everywhere | `URLSession` networking and streaming, JSON, `UserDefaults`; `FileManager` and `JSONEncoder`/`JSONDecoder` for the lecture history (`Backend/History/`); `XMLParser` for Word and PowerPoint text |
| PDFKit | `Backend/Documents/DocumentToText.swift` | Reading text from PDFs and rendering scanned pages |
| Vision | `Backend/Documents/DocumentToText.swift`, `Backend/VideoToFrames.swift` | On-device text recognition (`RecognizeTextRequest`) for scanned pages, images, and the slide frames (whose words correct misheard terms) |
| Compression | `Backend/Documents/ZipArchive.swift` | Inflating the deflate-compressed entries inside .docx and .pptx files |
| FoundationModels | `Backend/AppleIntelligence/AppleIntelligence.swift` | Apple Intelligence's on-device model: notes, slide descriptions for models that can't see images, token counts, and context size (`SystemLanguageModel`, `LanguageModelSession`, image `Attachment`) |
| Security | `Frontend/AppSettings.swift` | Storing API keys in the Keychain |
| Swift Testing | `Lecture Me FasterTests/` | Unit tests (test target only, not shipped in the app) |

## AI services (called over HTTP from `Backend/FileToAI.swift` and `Backend/LongLectures/LongLectures.swift`, no SDKs)

| Service | Endpoint | Notes |
|---|---|---|
| Ollama | `POST /api/chat`, `GET /api/tags`, `POST /api/show` (a model's context length) | Local models, free. Default server `http://localhost:11434` |
| Claude (Anthropic API) | `POST https://api.anthropic.com/v1/messages`, `GET /v1/models` (model list, paginated) and `GET /v1/models/{model}` (`max_input_tokens`) | Paid, needs an API key. Streaming Messages API |
| OpenAI | `https://api.openai.com/v1`: `POST /chat/completions`, `GET /models` | Paid, needs a key |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta/openai`: Google's OpenAI-compatible endpoints; plus Google's own `GET /v1beta/models?key=…` for each model's context window (`inputTokenLimit`), which the OpenAI-format list leaves out | Needs a key |
| DeepSeek | `https://api.deepseek.com`: `POST /chat/completions`, `GET /models` | Paid, needs a key |
| OpenRouter | `https://openrouter.ai/api/v1` | Many providers' models through one key |
| LM Studio | `http://localhost:1234/v1` | Local, free |
| Other OpenAI-compatible servers | `POST {address}/chat/completions`, `GET {address}/models` (where offered) | llama.cpp, vLLM, Groq, Mistral, and similar |

## Tooling

- Xcode 27.2, Swift 6.4 toolchain (Swift 5 language mode, main-actor default isolation)
- Targets: macOS, iOS, and visionOS 27.2

Test-only: CoreText (drawing text into generated PDFs and images in `TestDocuments.swift`).
