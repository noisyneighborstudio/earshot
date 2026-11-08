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

## Releases

Earshot updates itself with Sparkle 2. Every push to `main` runs `.github/workflows/release.yml`: tests, then semantic-release. Conventional commits pick the version (`feat:` minor, `fix:` patch, `!` major); a push with no releasable commits publishes nothing. `CFBundleVersion` is the workflow run number, which only increases.

- `scripts/release-prepare.sh` archives a Developer ID build, notarizes and staples it when the notary secrets exist, and zips it.
- `scripts/publish-appcast.sh` signs the zip with the Sparkle EdDSA key, checks it against the app's `SUPublicEDKey`, uploads it and then `appcast.xml` to the Cloudflare R2 bucket `earshot-releases` (custom domain `https://earshot-updates.noisyneighbor.studio/appcast.xml`), and links the download from the GitHub release.

Only Release builds check for updates (`EARSHOT_FEED_URL` in `project.yml`). The Sparkle key is login-keychain account `earshot` (`generate_keys --account earshot`).

| Secret | What |
| ------ | ---- |
| `DEVELOPER_ID_CERTIFICATE_BASE64` | Developer ID Application certificate + private key as .p12, base64 |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | the .p12 export password |
| `BUILD_KEYCHAIN_PASSWORD` | any random string (throwaway CI keychain) |
| `DEVELOPER_ID_APPLICATION` | identity name, e.g. `Developer ID Application: Name (TEAMID)` |
| `SPARKLE_PRIVATE_KEY` | `generate_keys --account earshot -x <file>` |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token with Workers R2 Storage: Edit (account `76a59d23…`) |
| `NOTARY_KEY_P8`, `NOTARY_KEY_ID`, `NOTARY_KEY_ISSUER` | App Store Connect API key; without them builds are signed but not notarized |
