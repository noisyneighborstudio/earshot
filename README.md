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

## Use your notes from any agent

Earshot ships a read-only MCP server, `earshot-mcp`, inside the app. Agents (Claude Code, Codex, Cursor, VS Code, Claude Desktop, …) can then search your meeting notes, transcripts, action items and dictations. It runs locally over stdio, reads `~/Library/Application Support/Earshot`, and never writes there.

**One click:** Settings › Connect to Agents. Each agent gets an Install button and shows whether it's connected. Move NN Earshot to Applications first, because agents launch the helper from that path.

**By hand** (the helper is at `/Applications/NN Earshot.app/Contents/MacOS/earshot-mcp`):

| Agent | Install |
|---|---|
| Claude Code | `claude mcp add --scope user earshot -- "/Applications/NN Earshot.app/Contents/MacOS/earshot-mcp"` |
| Codex | `codex mcp add earshot -- "/Applications/NN Earshot.app/Contents/MacOS/earshot-mcp"` |
| Cursor | Settings › Connect to Agents › Install (opens Cursor's install link), or add the JSON below to `~/.cursor/mcp.json` |
| VS Code | Settings › Connect to Agents › Install (opens `vscode:mcp/install`), or run **MCP: Add Server…** with the command above |
| Claude Desktop | Settings › Connect to Agents › Install: Earshot builds `NN Earshot.mcpb` and opens it in Claude Desktop, which asks you to confirm. (Custom connectors take remote URLs only.) Or add the JSON below to `claude_desktop_config.json` and restart Claude |

```json
{
  "mcpServers": {
    "earshot": {
      "command": "/Applications/NN Earshot.app/Contents/MacOS/earshot-mcp"
    }
  }
}
```

| Tool | What it does |
|---|---|
| `search_notes` | Ranked search over titles, people, notes, action items and transcripts. Keyword ranking (BM25) is fused with on-device NaturalLanguage sentence embeddings. Filters: date range, kind, participant, platform, folder, starred, status |
| `list_meetings` | Newest first, with the same filters and paging |
| `get_meeting` | Notes markdown and metadata. The transcript is optional and paged, with speakers and timestamps |
| `list_action_items` | Open, done or all, filtered by owner, participant, meeting or date |
| `search_dictations` | Dictation history, filtered by text, app or date |

There are also resources (`earshot://meeting/<id>`, the notes plus the full transcript) and a `meeting_brief` prompt (person, topic) that collects your recent meetings with someone.

Example prompts:

- "What did we decide about pricing last week?"
- "What do I owe Dana? Check my open action items."
- "Brief me before my 1:1 with Kim." (or use the `meeting_brief` prompt)
- "Find where someone mentioned the Q3 budget in a call, and quote it."

A meeting with status `recording` is still being recorded, or Earshot quit during it. Its transcript is partial and it has no notes yet. If a file can't be read, results list it under `unreadable_files` and leave it out.

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
