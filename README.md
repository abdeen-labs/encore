# Encore

A free, open-source macOS app for local voice AI on Apple Silicon: text to speech, voice cloning, voice design, voice changing, multi-speaker conversations, and transcription. Everything runs on your Mac.

## Run it

You need an Apple Silicon Mac, macOS 27.2, and Xcode 27.2.

1. Install Apple's Metal Toolchain once (MLX's shaders don't compile without it):

   ```bash
   xcodebuild -downloadComponent MetalToolchain
   ```

2. Open `Encore.xcodeproj` and run the `Encore` scheme.

3. Optional, for the voice changer, word-level timestamps, and Chatterbox Multilingual, set up the Python helper once (downloads a standalone Python 3.13 and `mlx-audio` into the git-ignored `PythonHelper/.runtime`, about 680 MB):

   ```bash
   Scripts/setup-python-runtime.sh
   ```

4. Optional, for MP3 export and mkv/webm input:

   ```bash
   brew install ffmpeg
   ```

Models are downloaded from the Models screen into the standard Hugging Face cache (`~/.cache/huggingface`).

## Test it

```bash
cd Packages/EncoreCore && swift test
```

Anything that runs MLX has to be built by Xcode, not `swift build`. The developer CLI drives the same service layer as the app:

```bash
cd Packages/EncoreCore && xcodebuild -scheme encore-cli -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath ../../build/cli -skipPackagePluginValidation -skipMacroValidation build
```

```bash
build/cli/Build/Products/Debug/encore-cli service speak --model kokoro --text "Hello from Encore." --out hello.wav --root /tmp/encore-test
```

Run `encore-cli` with no arguments for the other commands. `--root` keeps history and voices out of the app's real folders.

To check screens without clicking through them, build the app from the command line and have it render itself to PNGs:

```bash
xcodebuild -project Encore.xcodeproj -scheme Encore -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath build/app -skipPackagePluginValidation -skipMacroValidation build
```

```bash
build/app/Build/Products/Debug/Encore.app/Contents/MacOS/Encore --snapshot /tmp/encore-shots
```

## Where things are

| Path | What |
|---|---|
| `Encore/` | The SwiftUI app: `App/` (shell), `Design/` (theme and components), `Features/` (one folder per screen, plus `Shared/`). |
| `Packages/EncoreCore/Sources/EncoreCore/` | Everything without UI: model catalog, service layer, Hugging Face downloads, audio, text, stores, and the Python helper bridge. |
| `Packages/EncoreCore/Sources/EncoreMLX/` | The in-process MLX Swift engines. |
| `Packages/EncoreCore/Sources/encore-cli/` | The developer CLI. |
| `PythonHelper/` | The Python worker for models with no Swift port. |
| `Scripts/` | Python runtime setup, and the release scripts. |

All generation goes through `EncoreService` (`Service/EncoreService.swift`). Its request and event types are `Codable`, so a local HTTP API can wrap it directly.

## Add a model

Add a JSON manifest to `Packages/EncoreCore/Sources/EncoreCore/Resources/Manifests/`. It declares the Hugging Face repos, license, capabilities, voices, and every generation parameter; the UI is rendered from it. The manifest's `engine` key must be one a backend supports: see `MLXEngines.swift` for Swift and `PythonHelper/encore_helper/` for Python. `ManifestTests` checks it.
