<p align="center">
  <img src="Sources/Resources/Images/app-icon.png" width="128" />
</p>

<h1 align="center">Masko Code</h1>

<p align="center">
  A living mascot that floats above your windows, reacts to Claude Code, and lets you handle everything without leaving your flow.
</p>

<p align="center">
  <a href="https://github.com/RousselPaul/masko-code/releases/latest"><img src="https://img.shields.io/github/v/release/RousselPaul/masko-code?style=flat-square&color=f95d02" alt="Release" /></a>
  <img src="https://img.shields.io/badge/macOS-14.0%2B-black?style=flat-square&logo=apple" alt="macOS 14+" />
  <img src="https://img.shields.io/badge/Universal-arm64%20%2B%20x86__64-black?style=flat-square" alt="Universal Binary" />
  <img src="https://img.shields.io/badge/license-MIT-blue?style=flat-square" alt="License" />
</p>

<p align="center">
  <a href="https://github.com/RousselPaul/masko-code/releases/latest"><strong>Download</strong></a> · <a href="https://masko.ai/claude-code"><strong>Website</strong></a> · <a href="https://masko.ai"><strong>Custom Mascots</strong></a>
</p>

---

<!-- Add a screenshot or GIF here: ![Screenshot](docs/screenshot.png) -->

## Features

| | Feature | Description |
|---|---|---|
| 🎭 | **Animated overlay** | A mascot that floats above all windows and reacts to Claude Code state — click or hover to interact |
| 🔐 | **Permission handling** | Approve, deny, or defer tool use requests from a speech bubble — select with `⌘1-9`, permissions stack in a queue |
| 💬 | **Question answering** | Answer Claude's questions directly from the overlay |
| 📋 | **Plan review** | Review and approve plans without opening your terminal |
| 📊 | **Session tracking** | Monitor active sessions, subagents, and status at a glance |
| 🔔 | **Notification dashboard** | Priority levels, resolution tracking, color-coded activity feed |
| 🖥️ | **Find the right terminal** | Jump to the correct terminal tab — supports 13 terminals and IDEs including iTerm2, Ghostty, VS Code, Cursor, and more |
| 🔀 | **Session switcher** | Double-tap `⌘` to switch between Claude Code sessions |
| 😴 | **Snooze** | Right-click to hide the mascot for 15 min, 1 hour, or indefinitely |
| ↔️ | **Resizable** | Drag to resize or pick a preset (S / M / L / XL) from the context menu |
| 🔄 | **Auto-updates** | Built-in Sparkle updates — always on the latest version |

## How It Works

```
┌─────────────┐     hook events     ┌─────────────┐
│  Claude Code │ ──────────────────▶ │    Masko     │
│  (terminal)  │                     │  (menu bar)  │
└─────────────┘                     └─────────────┘
        │                                   │
        │  fires hooks on tool use,         │  updates mascot animation,
        │  sessions, notifications          │  shows permission prompts,
        │                                   │  tracks sessions
        ▼                                   ▼
   ~/.claude/settings.json          local HTTP :49152
```

1. **Download the app** — Install the DMG. Lives in your menu bar, no dock clutter.
2. **Grant accessibility** — First launch installs Claude Code hooks automatically into `~/.claude/settings.json`.
3. **Pick a mascot** — Choose the default Masko or bring your own from [masko.ai](https://masko.ai).
4. **Start coding** — Open a terminal, run Claude Code. Your mascot springs to life.

## Keyboard Shortcuts

All shortcuts work globally — no need to focus the app.

| Shortcut | Action |
|---|---|
| `⌘M` | Toggle dashboard (customizable in Settings) |
| `⌘1-9` | Select Nth pending permission |
| `⌘Enter` | Approve selected permission |
| `⌘Esc` | Deny / dismiss permission |
| `⌘L` | Collapse / defer topmost permission |
| `Double-tap ⌘` | Open session switcher (2+ sessions) |
| `↑ / ↓` | Navigate session switcher |
| `Tab / Shift+Tab` | Cycle sessions |
| `Enter` | Confirm session selection |
| `Esc` | Close session switcher |

The focus toggle shortcut can be rebound to any key combination in Settings.

Right-click the mascot to open the **context menu** — snooze, resize, or close the overlay.

## Custom Mascots

The default Masko fox is included. Want your own character? Create one on [masko.ai](https://masko.ai) with AI-generated animations for every state (idle, working, attention). Export and load it into the desktop app in one click.

## Supported Terminals & IDEs

Masko works with any terminal that runs Claude Code. Terminal focus (`⌘M`) support varies by app:

| Level | App | How |
|---|---|---|
| **Exact tab** | VS Code, VS Code Insiders, Cursor, Windsurf, Antigravity | IDE extension (auto-installed) |
| **Exact tab** | iTerm2, Terminal.app | AppleScript TTY matching |
| **App focus** | Ghostty, Kitty, WezTerm, Alacritty, Warp, Zed | Process activation |

Click a session in the dashboard or click the mascot overlay to jump to the right terminal.

## Requirements

- macOS 14.0+ (Sonoma)
- Apple Silicon or Intel Mac
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) installed

## Install

Download the latest `.dmg` from [**Releases**](https://github.com/RousselPaul/masko-code/releases/latest).

## Build from Source

```bash
git clone https://github.com/RousselPaul/masko-code.git
cd masko-code
swift build
swift run
```

## Project Structure

```
Sources/
├── App/             # App entry point & lifecycle
├── Models/          # Data models (sessions, events, hooks)
├── Services/        # HTTP server, hook installer, update checker
├── Stores/          # Observable state (sessions, notifications)
├── Views/           # SwiftUI views (overlay, permission prompt, dashboard)
├── Utilities/       # Helpers
└── Resources/       # Assets, images, app icon
scripts/             # DMG packaging scripts
vscode-extension/    # IDE click-to-focus extension
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to get involved.

## License

[MIT License](LICENSE) — Copyright (c) 2026 Masko.

---

> **Note:** This project has no cryptocurrency or token associated with it. Any coin using the Masko or Clippy name is not affiliated with us.
