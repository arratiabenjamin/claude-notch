# Claude Notch

> Native macOS app that surfaces your Claude Code sessions in a floating glass panel.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform: macOS 14+](https://img.shields.io/badge/Platform-macOS%2014%2B-blue.svg)]()
[![Swift 6](https://img.shields.io/badge/Swift-6-orange.svg)]()

A native counterpart to [`claude-code-notifier`](https://github.com/arratiabenjamin/claude-code-notifier).
Reads the same `~/.claude/active-sessions.json` state file and renders it through
SwiftUI + `NSVisualEffectView` for that real-glass Control Center look that web
widgets can't quite reach.

## Status

Early scaffold. The MVP design is in active development. See [issues](https://github.com/arratiabenjamin/claude-notch/issues) for what's coming.

## Why a separate repo?

`claude-code-notifier` owns the backend hooks and writes the state file.
`claude-notch` owns one of the UI front-ends. The state file is the contract.
This way each component evolves independently.

## Build

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
xcodegen generate
open ClaudeNotch.xcodeproj
# Cmd+R to build & run
```

The `.xcodeproj` is regenerated from `project.yml` — that file is the source of truth.

## License

MIT — see [LICENSE](LICENSE).

## Made by

Built by [Benjamín Arratia](https://github.com/arratiabenjamin) at Velion — a one-person software studio.
