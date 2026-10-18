# VoiceBoy

**Ultra-fast, private local voice dictation for macOS powered by FUTO speech models and whisper.cpp.**

---

<p align="center">
  <img src="Resources/AppIconTile.png" alt="VoiceBoy App Icon" width="128" />
</p>

<p align="center">
  <a href="https://github.com/unamatasanatarai/voiceboy/releases">
    <img src="https://img.shields.io/badge/Download%20Latest%20Release-macOS%20(DMG)-007AFF?style=for-the-badge&logo=apple&logoColor=white" alt="Download Latest Release (macOS DMG)" />
  </a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Platform-macOS%2012.0%2B-black?style=flat-square" alt="Platform: macOS 12+" />
  <img src="https://img.shields.io/badge/Language-Swift%205-orange?style=flat-square" alt="Language: Swift 5" />
  <img src="https://img.shields.io/badge/Engine-whisper.cpp-blue?style=flat-square" alt="Engine: whisper.cpp" />
  <img src="https://img.shields.io/badge/Speech%20Models-FUTO%20Voice%20Input-purple?style=flat-square" alt="Models: FUTO" />
  <img src="https://img.shields.io/badge/License-GPL--2.0-green?style=flat-square" alt="License: GPL-2.0" />
</p>

---

## Why VoiceBoy?

Cloud-based dictation services send your raw voice data to remote servers, require constant internet access, and introduce noticeable round-trip network delays. Traditional offline transcription tools are frequently bulky, cumbersome to configure, or heavily reliant on Python runtime environments and complex FFmpeg dependency stacks.

**VoiceBoy solves this with a lightweight, zero-cloud native macOS application:**

* **100% Local & Private:** Inference runs strictly on-device through an embedded `whisper.cpp` engine accelerated by Apple's Accelerate BLAS framework. No audio or text ever leaves your machine.
* **Instant System-Wide Dictation:** Trigger voice input from any application with a global hotkey (`⌥[` by default). VoiceBoy types your words directly into the active cursor location.
* **Dynamic Audio Context:** Unlike conventional Whisper implementations that pad every recording to 30 seconds, VoiceBoy shrinks the encoder compute window to match your exact speech duration, cutting inference latency to fractions of a second.
* **Native Apple Audio Pipeline:** Ingests and resamples microphone input and media files using Apple's AVFoundation and CoreAudio frameworks—no external binaries or FFmpeg required.
* **Dual-Mode Flexibility:** Operates as an unobtrusive menu bar utility with a dark minimalist UI or as a scriptable command-line tool for automated workflows.

---

## Key Capabilities

### System-Wide Push-to-Talk Dictation
Press `⌥[` anywhere across macOS to begin recording. An intuitive floating HUD appears at the top of your screen displaying live volume meters and real-time speech previews. Press `⌥[` again to finish, or hit `Esc` to cancel instantly without touching your inputs.

### Direct Auto-Typing with Clipboard Protection
Upon completing dictation, VoiceBoy uses macOS Accessibility APIs to automatically paste your transcribed text directly into whichever text input is active. If you disable the "Copy to clipboard" setting, VoiceBoy captures a snapshot of your existing clipboard, pastes your speech, and restores your previous clipboard contents with full fidelity.

### Optimized FUTO Voice Input Models
VoiceBoy integrates specialized speech models from FUTO, ranging from lightweight 39M-parameter streaming models to high-accuracy 244M-parameter models. The built-in model manager enables 1-click downloads directly to your local XDG data directory (`~/.local/share/voiceboy/models`).

### Adaptive Silence Trimming & Dynamic Context
Every audio stream passes through an adaptive threshold silence stripper and a dynamic context encoder. By processing only voiced segments and sizing the attention window to the input length, VoiceBoy avoids unnecessary compute and eliminates common Whisper blank-audio artifacts.

### Native Multi-Format Audio Ingestion
Whether transcribing live speech or existing audio files, VoiceBoy handles `.wav`, `.m4a`, `.mp3`, `.aac`, and `.flac` formats natively via CoreAudio, converting all inputs to 16kHz Float32 mono PCM on the fly.

### Minimalist Menu Bar & HUD
Built with a sleek, dark-canvas interface that respects your screen space. Toggle between a stealthy menu-bar-only mode (accessory) or a standard Dock application, customize hotkeys with an interactive key recorder, and configure your audio archive directory.

---

## Product Experience

```
1. Trigger       Press ⌥[ (or your custom hotkey) from any application.
2. Dictate       Speak naturally while the floating HUD displays real-time speech feedback.
3. Auto-Paste    Press ⌥[ to finish; your text is typed directly into the active field.
4. Cancel        Hit Esc at any time to abort the session without pasting.
```

---

## Supported Speech Models

VoiceBoy includes built-in support for FUTO Voice Input models, selectable and downloadable directly within the app:

| Model | Parameters | Size | Target Use Case |
| :--- | :--- | :--- | :--- |
| **English-39** (`futo-english-39.bin`) | 39M params | ~43 MB | Ultra-low latency; optimized for real-time streaming and fast typing. |
| **English-74** (`voice-input-english-74.bin`) | 74M params | ~82 MB | Balanced default; enhanced vocabulary for daily dictation. |
| **English-244** (`voice-input-english-244.bin`) | 244M params | ~264 MB | Maximum accuracy; handles technical jargon, accents, and noisy environments. |
| **Multilingual-74** (`voice-input-multilingual-74.bin`) | 74M params | ~82 MB | Fast multi-language transcription (Polish, German, Spanish, French, Japanese, etc.). |
| **Multilingual-244** (`voice-input-multilingual-244.bin`) | 244M params | ~264 MB | High-precision transcription across diverse international languages. |

---

## Command-Line Interface (CLI)

The compiled `VoiceBoy` binary doubles as a standalone command-line utility. Run audio files directly from the terminal or inspect available models:

```bash
# Transcribe an audio file using the default model
VoiceBoy recording.wav

# Transcribe an M4A file with a specific model and language
VoiceBoy voice_memo.m4a --model futo-english-39.bin --language en

# Inspect all supported FUTO models and local installation status
VoiceBoy --list-models

# Force launch the graphical interface from terminal
VoiceBoy --gui
```

### CLI Options

| Option | Description |
| :--- | :--- |
| `<AUDIO_FILE>` | Path to input audio (`.wav`, `.m4a`, `.mp3`, `.aac`, `.flac`). |
| `--model <name>` | Specify model filename or path (default: `voice-input-multilingual-244.bin`). |
| `--language <code\>`, `-l` | Set transcription language code (e.g. `en`, `pl`) or `auto` for auto-detect. |
| `--list-models` | Display all supported FUTO models, specifications, and install status. |
| `--no-dynamic-ctx` | Disable dynamic context shrinking and use standard 30-second Whisper window. |
| `--no-trim` | Disable automatic leading and trailing silence trimming. |
| `--gui` | Launch the graphical user interface. |
| `-h`, `--help` | Show CLI usage documentation. |

---

## Quick Start

### Option 1: Install Pre-Built DMG

1. Download `VoiceBoy-<version>.dmg` from [Releases](https://github.com/unamatasanatarai/voiceboy/releases).
2. Open the disk image and drag **VoiceBoy.app** into your `/Applications` folder.
3. Launch VoiceBoy. Grant **Microphone** and **Accessibility** permissions when prompted (Accessibility is required for automated typing into other apps).
4. Select your preferred language and model, then press `⌥[` to start dictating.

### Option 2: Build from Source

#### Prerequisites
* macOS 12.0 or later
* Xcode Command Line Tools (`xcode-select --install`)
* CMake (`brew install cmake`)

#### Build Steps

```bash
# Clone repository with whisper.cpp submodule
git clone https://github.com/unamatasanatarai/voiceboy.git
cd voiceboy
git submodule update --init --recursive

# Compile native macOS bundle and CLI binary
make build

# Launch application
make run
```

---

## Configuration & Settings

VoiceBoy persists your preferences via `UserDefaults`:

* **Global Shortcut:** Click the shortcut recorder in the settings panel to bind any key combination (default: `⌥[`).
* **Post-Processing Pass:** Toggle between instant live-transcript pasting and an optional high-accuracy finalization pass.
* **Clipboard Retention:** Toggle whether transcribed text remains on your macOS clipboard after pasting.
* **Dock Icon Visibility:** Toggle between showing a standard Dock icon or running exclusively in the macOS menu bar.
* **Recordings Archive:** Audio recordings can automatically save to your preferred directory (`~/Music/VaultBoy-Recordings` by default). Click the path in the footer to change or open the folder in Finder.
* **Accidental Quit Protection:** VoiceBoy intercepts `⌘Q` and requires a double-tap within 2 seconds to prevent accidental app termination during work.

---

## Verification & Testing

VoiceBoy includes an automated test suite that validates binary execution, CLI options, model catalog resolution, and application bundle integrity:

```bash
# Run the test suite
make test
```

---

## Makefile Targets

| Target | Description |
| :--- | :--- |
| `make build` | Compiles the `whisper.cpp` static library and native `VoiceBoy.app` bundle. |
| `make run` | Terminates any running instance, recompiles, and launches `VoiceBoy.app`. |
| `make kill` | Stops all active VoiceBoy processes. |
| `make test` | Runs the automated verification test suite. |
| `make dmg` | Packages the application into a styled macOS `.dmg` with custom background art. |
| `make release <version>` | Bumps version, runs tests, creates styled DMG, and tags release. |
| `make revoke` | Resets TCC permissions and clears macOS LaunchServices caches for clean testing. |
| `make clean` | Removes build outputs and temporary compiler caches. |

---

## License

VoiceBoy is open-source software licensed under the [GNU General Public License v2.0](LICENSE).
