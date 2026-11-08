# Earshot

Menu-bar dictation for macOS. Hold a key, talk, release: your words are transcribed on-device and pasted at the cursor. Meeting notes are summarized by Claude.

## Run

```sh
brew install xcodegen
xcodegen generate
open Earshot.xcodeproj   # or: xcodebuild -scheme Earshot -derivedDataPath build build
```

First launch: grant Microphone, Accessibility and Input Monitoring from the menu, The on-device speech model downloads automatically. Meeting notes and titles use the Claude Code CLI (`claude`) with your existing login; no API key.

## Use

- **Hold fn** (configurable): dictate; release to insert.
- **Double-tap fn**: hands-free; press again to finish.
- **Esc**: cancel.

If fn opens the emoji picker, set System Settings › Keyboard › "Press 🌐 key to" → "Do Nothing".

## How it works

| Stage | File |
|---|---|
| Global hotkey (CGEventTap on its own run-loop thread) | `Earshot/Input/HotkeyMonitor.swift` |
| Mic → speech-model audio format | `Earshot/Audio/AudioCapture.swift` |
| On-device transcription (Apple SpeechAnalyzer) | `Earshot/Transcription/` |
| Focused app + text before the cursor (Accessibility) | `Earshot/Context/` |
| Paste with clipboard restore | `Earshot/Insertion/` |
| Meeting notes + titles (Claude via `claude -p`) | `Earshot/Meetings/` |
| State machine | `Earshot/Core/DictationController.swift` |
