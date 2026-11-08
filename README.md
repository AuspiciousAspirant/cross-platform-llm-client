# PrivateLM — Cross-Platform Distributed LLM Client

[![Live Web App](https://img.shields.io/badge/Live_Demo-Try_Web_App-02569B?style=for-the-badge&logo=flutter&logoColor=white)](https://ai-chat-orailnoor.web.app/)
[![Platforms](https://img.shields.io/badge/Platforms-Windows%20%7C%20macOS%20%7C%20Linux%20%7C%20Android%20%7C%20iOS-blue?style=for-the-badge)](https://github.com/AuspiciousAspirant/cross-platform-llm-client)
[![Protocol](https://img.shields.io/badge/LAN%20Cluster-ggml--rpc%20%3A50052-purple?style=for-the-badge)](https://github.com/AuspiciousAspirant/cross-platform-llm-client)

A production-ready, cross-platform AI workstation client built with Flutter. It unifies local on-device LLM inference across **PCs (Windows, macOS, Linux)** and **Mobile devices (Android, iOS)** with cloud API access and **bi-directional LAN model layer splitting**.

---

## Key Highlights

- **Bi-Directional LAN Distributed Cluster** — Split large GGUF models across devices over Wi-Fi / Ethernet on port `50052` using `llama.cpp`'s native RPC protocol (`ggml-rpc`).
  - **PC Master + Mobile Workers**: Your PC drives the UI and offloads model layers to phones or tablets over LAN.
  - **Phone Master + PC Worker**: Your phone drives the UI and offloads 50–80% of layers to your desktop PC's GPU or high-speed RAM.
  - **One-Click PC Worker Mode**: Run `rpc-server` daemon directly inside the app with live connection logs and benchmarked memory bandwidth (GB/s).
- **Responsive Desktop Workstation UI** — Modern technical design featuring a collapsible navigation rail (`width >= 800px`), docked split-pane chat history (`width >= 900px`), and center-constrained reading view (`maxWidth: 860px`).
- **Local Inference Across Desktop & Mobile** — Download and run GGUF models directly on Windows, macOS, Linux, Android, and iOS using GPU acceleration (Vulkan, Metal, CUDA).
- **Cloud API Fallback** — Seamlessly switch to OpenAI, Anthropic, Google Gemini, or Kimi (Moonshot AI).
- **Multimodal Chat** — Send text and images in conversations with vision projector support (`mmproj`).
- **Persistent Sessions** — All chats and settings stored locally via Hive. Nothing leaves your device unless you explicitly choose cloud mode.
- **Auto-Config & Benchmark** — Detects device memory and benchmarks memory bandwidth in a background `Isolate` for optimal layer splitting.

---

## LAN Distributed Inference Architecture

```
┌────────────────────────────────────────────────────────────────────────┐
│                   Local Area Network (Wi-Fi / Ethernet)                │
└────────────────────────────────────┬───────────────────────────────────┘
                                     │
           ┌─────────────────────────┴─────────────────────────┐
           ▼                                                   ▼
┌──────────────────────────────────────┐    ┌──────────────────────────────────────┐
│       🖥️ PC Master Node (Windows)     │    │       📱 Mobile Worker Node (Android)│
│  • Loads GGUF Model                  │    │  • Listens on LAN IP:50052           │
│  • Keeps Vocab / Embedding Layers    │    │  • Holds 40–70% of Transformer Layers│
│  • Streams Tokens via OpenAI SSE     │    │  • GPU Vulkan / CPU Compute Buffer   │
└──────────────────┬───────────────────┘    └──────────────────┬───────────────────┘
                   │                                           │
                   └─────── 1–5ms Low-Latency ggml-rpc ────────┘
                                   (Port 50052)
```

---

## Supported Platforms

| Platform | Local Inference | Distributed Cluster | Cloud APIs | Acceleration |
| :--- | :---: | :---: | :---: | :--- |
| **Windows** | ✅ Yes | ✅ Master & Worker | ✅ Yes | DirectX 12, Vulkan, CPU |
| **Android** | ✅ Yes | ✅ Master & Worker | ✅ Yes | Vulkan GPU, CPU NEON |
| **iOS / iPad** | ✅ Yes | ✅ Master & Worker | ✅ Yes | Metal GPU acceleration |
| **macOS** | ✅ Yes | ✅ Master & Worker | ✅ Yes | Metal GPU, Apple Silicon |
| **Linux** | ✅ Yes | ✅ Master & Worker | ✅ Yes | Vulkan, CUDA, CPU |
| **Web** | ❌ No | ❌ No | ✅ Yes | Cloud-only fallback |

---

## Build Configuration

### Prerequisites

- Flutter SDK >=3.3.0
- Dart SDK >=3.3.0
- Visual Studio 2022 with Desktop C++ workload (Windows)
- Android SDK (API 28+) & NDK (Android)
- Xcode 15+ (macOS / iOS)

### Windows Desktop Build

```powershell
flutter pub get
flutter build windows --release
```

To quickly set up `llama-server.exe` and `rpc-server.exe` in `bin/`:
```powershell
.\scripts\download_desktop_binaries.ps1
```

### Android Build

```bash
flutter pub get
flutter build apk --release --split-per-abi
```

### iOS Build

```bash
flutter pub get
cd ios && pod install && cd ..
flutter build ios --release
```
┌─────────────────────────────────────────────────────────────┐
│                        UI Layer                              │
│   ChatView / ModelView / ServerView / SettingsView          │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                    Controllers (GetX)                        │
│   ChatController · TaskController · ModelController         │
│   SettingsController · HomeController                       │
└──────────────────────────┬──────────────────────────────────┘
                           │
┌──────────────────────────▼──────────────────────────────────┐
│                      Services                                │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │ InferenceService│  │  CloudService   │  │DownloadSvc  │ │
│  │  (local GGUF)   │  │ (OpenAI/Claude/ │  │ (model dl)  │ │
│  │                 │  │  Gemini/Kimi)   │  │             │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
│  ┌─────────────────┐  ┌─────────────────┐  ┌─────────────┐ │
│  │  HiveService    │  │ DeviceInfoSvc   │  │ExecutionSvc │ │
│  │  ( persistence) │  │  (RAM/GPU tier) │  │ (bg tasks)  │ │
│  └─────────────────┘  └─────────────────┘  └─────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Local Inference (Android)

The app uses `llama_flutter_android`, a custom Flutter plugin wrapping `llama.cpp` for ARM64 devices. At runtime it:

1. **Detects GPU capabilities** via Vulkan to determine offload layers.
2. **Selects thread count** based on device tier (ultra / high / mid / low).
3. **Loads the GGUF model** with progress streaming.
4. **Generates tokens** via `generateChat()` with native chat-template support (ChatML, Llama-3, Gemma, Phi).
5. **Falls back** to manual prompt construction if native templates fail.

Idle detection (5s) and hard timeouts (180s) keep the UX responsive even on underpowered hardware.

### Cloud Inference

`CloudService` normalizes four different API shapes into a single interface:

- **OpenAI** — standard `/v1/chat/completions`
- **Anthropic** — Messages API with separate system param
- **Google Gemini** — `generateContent` with inline image base64
- **Kimi** — OpenAI-compatible endpoint from Moonshot AI

API keys are stored in Hive and never transmitted anywhere except to the provider's endpoint.

### Cross-Platform Abstraction

Local inference is conditionally compiled:

- **Android** → `inference_android.dart` (full llama.cpp engine)
- **Web** → `inference_stub.dart` (cloud-only, local coming soon)
- **iOS** → `inference_android.dart` (full llama.cpp engine via Metal GPU)

The `InferenceService` exposes `supportsLocalInference` so the UI can hide local-model UI on unsupported platforms.

---

## Supported Platforms

| Platform | Local Inference | Cloud APIs | Notes                           |
| -------- | --------------- | ---------- | ------------------------------- |
| Android  | ✅ Yes          | ✅ Yes     | CPU offload via NEON; minSdk 28 |
| iOS      | ✅ Yes          | ✅ Yes     | Metal GPU acceleration          |
| Web      | ❌ No           | ✅ Yes     | Cloud-only (local coming soon)  |

### iOS / iPad (Installation via AltServer)
The iOS/iPad release is distributed as a sideloadable IPA file. Due to the RAM requirements for local models, iPad is the recommended iOS target, but it can be installed on iPhones.

Here is how you can install the app using AltStore and AltServer:

**Prerequisites:**
* Ensure **AltServer** is installed and running on your Mac or Windows PC.
* Your iOS device must be connected to the same Wi-Fi network as your computer, or connected directly via a USB cable.
* You must have **AltStore** successfully installed on your iOS device.

**Installation Steps:**
1. **Download the IPA:** Go to the [Releases](https://github.com/orailnoor/cross-platform-llm-client/releases) page on your iOS device (using Safari) and download the latest `PrivateLM-iOS.zip` package, extract it to get the `.ipa` file.
2. **Open in AltStore:**
   * Locate the extracted `.ipa` file in your device's "Files" app.
   * Tap the **Share** button and select **AltStore** from the list of apps.
   * *Alternatively*, you can open the AltStore app, go to the **My Apps** tab, tap the **"+" (plus)** icon in the top-left corner, and select the downloaded IPA file.
3. **Install:** AltStore will begin installing the app. You may be prompted to enter your Apple ID credentials if this is your first time.
4. **Enable Developer Mode:** On iOS 16 and later, ensure "Developer Mode" is enabled in your device's Settings (`Settings > Privacy & Security > Developer Mode`) to launch the sideloaded app.
5. **Launch:** Once installation is finished, PrivateLM will appear in the **My Apps** tab in AltStore and on your device's home screen!

*Note: Sideloaded apps via AltStore expire after 7 days, but AltStore will attempt to automatically refresh them in the background when connected to the same Wi-Fi as your computer running AltServer.*

---

## Build Configuration

### Prerequisites

- Flutter SDK >=3.3.0
- Android SDK (API 26+)
- JDK 17
- NDK (bundled with Android SDK)

### Android

```bash
flutter pub get
flutter build apk --debug
```

Release APKs require a stable signing key. Copy
`android/key.properties.example` to `android/key.properties`, fill in the
keystore values, and keep both the key and its backup. Android accepts an APK
upgrade only when it is signed with the same key as the installed APK.

```bash
cp android/key.properties.example android/key.properties
flutter build apk --release --split-per-abi
```

Never rotate the signing key between GitHub releases. The per-ABI APKs must
also keep increasing the build number in `pubspec.yaml`.

### iOS

```bash
flutter pub get
cd ios
pod install
flutter build ios
```

### Web

```bash
flutter pub get
flutter build web --release
```

---

## License

MIT — see [LICENSE](./LICENSE) for details.
