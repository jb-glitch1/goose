# Goose — Mac build & developer handoff

How to build and run this app on a Mac, plus a map of the codebase. The Rust
core builds and tests on Linux; the **iOS app requires macOS + Xcode**.

## Prerequisites

- macOS with **Xcode** (the project targets a recent iOS SDK).
- **Rust** + iOS targets:
  ```sh
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
  rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
  ```
  The Xcode build runs `Scripts/build_ios_rust.sh` automatically to compile the
  Rust staticlib (`libgoose_core.a`) before linking.

## First build

1. Open `GooseSwift.xcodeproj` in Xcode.
2. **Signing:** select the `GooseSwift` target → Signing & Capabilities → set
   your Development Team (automatic signing). Adjust the bundle id
   (`com.goose.swift`) to one you own if needed. Same for the
   `GooseWorkoutLiveActivityExtension` target.
3. **Deployment target:** the project is set to a very high iOS version
   (placeholder) — set it to your device's actual iOS version or it won't
   install.
4. Build & run on a device (BLE needs real hardware; the simulator can't talk
   to a WHOOP band).

CLI build (no signing, simulator):
```sh
xcodebuild build -project GooseSwift.xcodeproj -target GooseSwift \
  -configuration Debug -sdk iphonesimulator CODE_SIGNING_ALLOWED=NO
```

Useful run-scheme env vars: `GOOSE_ENABLE_DIAGNOSTICS=1` (BLE logging),
`GOOSE_AUTO_HISTORICAL_SYNC=1`, `GOOSE_START_PHYSIOLOGY_CAPTURE=1`.

## Codebase map

```
GooseSwift/                          SwiftUI app (~132 files)
GooseWorkoutLiveActivityExtension/   Lock-screen / Dynamic Island widget
Rust/core/                           Rust protocol/parse/calc core (builds on Linux)
Scripts/build_ios_rust.sh            Xcode build phase → libgoose_core.a
docs/                                planning + these handoff docs
```

### App entry & navigation
- `GooseSwiftApp.swift` — `@main`; sets up `GooseAppModel` (state) + `AppRouter`
  (navigation), deep links (`gooseswift://`), scene phase.
- `RootView.swift` → onboarding or `AppShellView.swift` (TabView: Home, Health,
  Coach, More).

### Bluetooth (real hardware path)
- `GooseBLEClient.swift` (+ `+CentralDelegate`, `+PeripheralDelegate`,
  `+Parsing`, `+Commands`, `+HistoricalCommands/Handlers`, `+VitalsAndLogging`).
- Talks to WHOOP Gen5 (`fd4b…` UUIDs) and Gen4 (`6108…`), plus standard HR
  (`180D`/`2A37`). Raw BLE frames → ingested in `GooseAppModel+NotificationPipeline`.

### Swift ↔ Rust bridge (JSON over C)
- `GooseRustBridge.swift` ↔ `GooseSwift-Bridging-Header.h` ↔
  `Rust/core/include/goose_core_bridge.h`.
- C ABI: `goose_bridge_handle_json(const char*) -> char*`,
  `goose_bridge_free_string`, `goose_core_version_json`. Requests/responses are
  JSON (`goose.bridge.request.v1`).

### Storage
- SQLite at `~/Library/Application Support/GooseSwift/goose.sqlite` (schema owned
  by the Rust core). AppStorage for onboarding/HR stats. Logs/exports/overnight
  spools under Documents and Application Support.

### Coach (now Claude)
- See `docs/coach-claude-migration.md`. API-key auth, Claude Messages API.

## Before installing on a phone

Read `SECURITY-REVIEW.md`. Headline: clean codebase, no secrets/telemetry, no
in-app path to brick the band. Recommended quick fix first: disable
`UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` in `Info.plist` so
biometric logs aren't browsable over USB.
