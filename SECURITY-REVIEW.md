# Goose — Pre-Install Security Review

**Scope:** Full static security review of the Goose iOS app (SwiftUI) + Rust core,
performed before installing on a personal iPhone. Covers secrets/credentials,
network egress, on-device data exposure, iOS permissions/entitlements, BLE
command (hardware) safety, Rust memory safety, and supply chain.

**Method:** Read-only static analysis of the full source tree. No code executed
on a device. Findings cite `file:line` evidence.

---

## Verdict: ✅ CONDITIONAL GO

This is a clean codebase. There are **no critical vulnerabilities, no hardcoded
secrets, no hidden telemetry/analytics, no backdoor network listener, and no
in-app way to brick your WHOOP band.** It is reasonable to install on a personal
phone.

Three things you should do/know first:

1. **The "Coach" feature sends your health data to OpenAI** (opt-in). If you
   don't sign into Coach, no health data leaves the device. *(Awareness, not a bug.)*
2. **Recommended 2-line fix before install:** disable iOS file sharing so your
   biometric logs in `Documents/` aren't browsable over USB/Files. *(See Fix #1.)*
3. **Don't casually use "Save Local Data File" / AirDrop export** — it bundles
   your entire biometric container into one shareable file.

Everything else is defense-in-depth that can follow at your pace.

---

## Risk summary

| # | Severity | Area | Finding | Leaves device? |
|---|----------|------|---------|----------------|
| 1 | HIGH (privacy) | Egress | Coach sends health metrics + heart rate + prompts to `chatgpt.com` (opt-in, after sign-in) | Yes — OpenAI |
| 2 | HIGH (exposure) | Storage | `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` expose `Documents/` (BLE live log + overnight biometric spools) to Files/USB | On-device, but reachable |
| 3 | MED/HIGH | Storage | Unscoped "Save Local Data File" bundles the whole container (DB, spools, logs, UserDefaults) and offers AirDrop/share | Only if you share it |
| 4 | MEDIUM | Storage | `goose-ble-live.log` in `Documents/` is written unconditionally (not gated by the diagnostics flag) | On-device |
| 5 | MEDIUM | Permissions | Background location "Always", auto-pause off, best accuracy — persistent-tracking capable (user-started; no egress found) | No |
| 6 | MEDIUM | Supply chain | `zip 0.6.6` is outdated and pulls in unused `aes`/`pbkdf2`/`bzip2`/`zstd` via default features | n/a |
| 7 | MEDIUM | Rust | Unbounded zip decompression (zip-bomb OOM) — only if you open a malicious archive; **not** BLE-reachable | n/a |
| 8 | LOW | Storage | Coach conversation history stored unencrypted in UserDefaults (local only) | No |
| 9 | LOW | Rust | No `catch_unwind` at FFI boundary; safety relies on `panic="abort"` (release/device is safe; debug/sim builds could hit UB) | No |
| 10 | LOW | Attack surface | `gooseswift://debug-command` deep link can trigger BLE commands — but constrained to a read-only catalog | No |

### Clean / positive findings
- **No hardcoded secrets, API keys, private keys, or credential blobs** anywhere.
- **No analytics, telemetry, crash reporting, or third-party tracking SDKs.**
- **Only two external hosts** the installed app can reach: `auth.openai.com` and
  `chatgpt.com`. Nothing else.
- **OAuth done correctly:** PKCE device flow, public client ID only (no embedded
  secret), tokens in the **iOS Keychain** (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`).
- **BLE hardware safety is sound:** firmware-load / reboot / force-trim / config /
  feature-flag writes exist only in the Rust catalog/validation tooling — **no
  Swift code path can send them.** The "Protected Controls" UI is an inert lock
  that sends nothing.
- **Rust BLE frame parser is panic-hardened and continuously fuzz-tested**
  (`property_tests.rs`); FFI boundary (3 functions) is sound with correct
  null-checks, UTF-8 validation, and alloc/free pairing.
- **No checked-in binaries / vendored code** despite `.gitignore` references —
  the `.a` libs are build artifacts only.
- **HealthKit scope is genuinely read-only, body-mass-only**, matching its usage string.
- The Rust core ships a **redaction/privacy-lint pipeline** that scrubs secrets,
  emails, and JWTs from exports.

---

## Detailed findings

### 1. Coach transmits health data to OpenAI — HIGH (sensitivity), opt-in
- Endpoint `https://chatgpt.com/backend-api/codex/responses`
  (`GooseSwift/OpenAICoachResponsesClient.swift:154,183`).
- Sends readiness, sleep/recovery/strain/stress scores, live & resting heart
  rate, vitals, activity sessions, your prompts, and recent transcript
  (`CoachLocalToolContext.swift:56-85`, `OpenAICoachChat.swift:376-402,444`).
- `"store": false` is set (`OpenAICoachResponsesClient.swift:88`) but data still
  transits OpenAI.
- **Fully gated:** `send()` aborts if not signed in (`OpenAICoachChat.swift:142-146`).
  Don't sign into Coach → no health data leaves the device.

### 2. File sharing exposes the Documents container — HIGH
- `Info.plist:34-35` (`LSSupportsOpeningDocumentsInPlace=true`) + `:59-60`
  (`UIFileSharingEnabled=true`) expose `Documents/` to Files app and Finder/USB.
- Exposed sensitive data: `Documents/GooseSwift/goose-ble-live.log`
  (`GooseBLEClient.swift:210-224`) and overnight spools with raw biometric
  payloads (`OvernightRawNotificationSpool.swift:136-153`).
- The SQLite DB and the gated `goose-ble.log` are in `Application Support/`
  (NOT exposed) — only the live log + overnight spools sit in the exposed path.
- Mitigated at rest by `FileProtectionType.completeUntilFirstUserAuthentication`,
  but readable once the phone is unlocked/connected to a trusted computer.

### 3. Unscoped full-container export → shareable — MED/HIGH
- `GooseLocalDataExporter.createBundle()` with no session ID produces a
  `full_app_container` export (`GooseLocalDataExporter.swift:432,452`) walking
  Application Support + Documents + `Library/Preferences`
  (`+FileSystem.swift:231-241`), base64'd into one JSON, offered via `ShareLink`
  (`MoreInfoViews.swift:59-67`). User-initiated only.

### 4. Always-on Documents BLE log — MEDIUM
- `goose-ble-live.log` is created with no diagnostics gate, and BLE
  sync/sensor/command-write events are persisted regardless of
  `GOOSE_ENABLE_DIAGNOSTICS` (`GooseBLEClient+VitalsAndLogging.swift:242-263,511-529`).

### 5. Background location "Always" — MEDIUM
- `ActivityLocationTracker.swift:22-43`: `allowsBackgroundLocationUpdates=true`,
  `pausesLocationUpdatesAutomatically=false`, best accuracy, `requestAlwaysAuthorization()`.
- Only starts on explicit workout start; shows the background indicator; no
  network egress of location found. Still stronger than a foreground-started
  workout strictly needs. **Grant "While Using," not "Always," when prompted.**

### 6–7. Supply chain & zip decompression — MEDIUM
- `zip 0.6.6` (`Cargo.toml:147`) is several majors behind and pulls in unused
  `aes`/`pbkdf2`/`bzip2`/`flate2`/`zstd` through default features.
- Zip entries are decompressed via unbounded `read_to_end`
  (`privacy_lint.rs:223`, `export.rs:7937`, `bin/...validation-suite.rs:813,1002`)
  → zip-bomb OOM if you open a malicious `.goosebundle.zip`. **Not** reachable
  over BLE. Zip-slip path traversal *is* already mitigated.

### 8–10. Lower severity
- **8** — Coach history in UserDefaults plaintext (`CoachChatTypes.swift:93-117`); local only.
- **9** — No `catch_unwind` in `goose_bridge_handle_json` (`bridge.rs:2505`);
  release/device uses `panic="abort"` (safe clean crash). Debug/sim could hit UB.
- **10** — `gooseswift://debug-command/<id>` validates `id` against a read-only
  catalog (`GooseBLEClient+UserActions.swift:39-44`); cannot reach destructive
  commands. Still, avoid untrusted `gooseswift://` links.

---

## Recommended fixes (prioritized)

**Before install (high value, low effort):**
1. **Disable file sharing.** Set `UIFileSharingEnabled` and
   `LSSupportsOpeningDocumentsInPlace` to `false` in `GooseSwift/Info.plist`,
   *or* move `goose-ble-live.log` + overnight spools from `Documents/` to
   `Application Support/`. Removes findings #2 and #4's exposure in one change.

**Behavioral (your habits, no code):**
2. Don't sign into Coach if you don't want health data going to OpenAI (#1).
3. Treat any `.goosebundle.json` from "Save Local Data File" as your full
   biometric record — don't AirDrop/share it casually (#3).
4. Grant location **"While Using"** and stop unused workouts (#5).

**Defense-in-depth (follow-up, on your Mac):**
5. `zip = { version = "<latest>", default-features = false, features = ["deflate"] }`
   — upgrades the dep and drops unused crypto/codec crates (#6).
6. Cap per-entry decompressed size with `Read::take(limit)` in the zip readers (#7).
7. Add a `catch_unwind` shim in `goose_bridge_handle_json` (#9).
8. Optionally move Coach history to the Keychain or encrypt it (#8).

---

## Bottom line
No backdoors, no secret exfiltration, no hardware-bricking path, and a
genuinely well-engineered (fuzz-tested, panic-hardened, redaction-aware) Rust
core. The residual risk is **your own data at rest and the opt-in OpenAI Coach**
— both within your control. Apply Fix #1 and install with confidence.
