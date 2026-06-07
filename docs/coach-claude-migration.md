# Coach → Claude (Anthropic) migration

The in-app **Coach** chat was migrated from the OpenAI/ChatGPT backend to
Anthropic's **Claude Messages API**. This was done in a Linux cloud environment
with **no Xcode/Swift toolchain**, so the Swift changes are **written but not
compiled** — they must be built and run on a Mac.

## What changed

| File | Change |
|------|--------|
| `GooseSwift/OpenAICoachResponsesClient.swift` | Rewritten: `ClaudeMessagesClient` (POST `https://api.anthropic.com/v1/messages`, SSE streaming), `ClaudeCoachRequestFactory` (system prompt + tools in Anthropic `input_schema` format), `ClaudeAPIKeyStore` (Keychain), `ClaudeCoachError`, `ClaudeToolUse`/`ClaudeStreamEvent`. |
| `GooseSwift/OpenAICoachChat.swift` | Rewritten: `OpenAICoachChatModel` now authenticates with an Anthropic API key and runs Claude's `tool_use` → `tool_result` agentic loop (up to 5 iterations). |
| `GooseSwift/CoachChatTypes.swift` | `CoachModelPreset` is now Opus 4.8 / Sonnet 4.6 / Haiku 4.5 (effort is optional — only sent for Opus/Sonnet). |
| `GooseSwift/CoachSignInScreen.swift` | OAuth device-code UI replaced with a secure API-key entry field. |
| `GooseSwift/CoachView.swift` | Sign-in wiring updated for the API-key flow. |

The class name `OpenAICoachChatModel` and the file names were **kept on purpose**
to avoid touching the Xcode project file (`project.pbxproj`) — adding/removing
files from the build would need a fragile pbxproj edit. Rename them later (see
Follow-ups) once you can build.

## Wire format (for reference)

- **Endpoint:** `POST https://api.anthropic.com/v1/messages`
- **Headers:** `x-api-key: <key>`, `anthropic-version: 2023-06-01`,
  `content-type: application/json`, `accept: text/event-stream`
- **Body:** `model`, `max_tokens: 4096`, `system`, `messages`, `stream: true`,
  `tools` (+ `tool_choice: {type: auto}`), and `output_config: {effort}` for
  Opus/Sonnet.
- **Streaming events handled:** `content_block_start` (text / tool_use),
  `content_block_delta` (`text_delta`, `input_json_delta`),
  `content_block_stop`, `message_delta` (`stop_reason`), `message_stop`, `error`.
- **Default model:** `claude-opus-4-8`.

## How to use (after building on Mac)

1. Open **Coach** → tap **Connect**.
2. Paste an Anthropic API key (`sk-ant-…`) from
   https://console.anthropic.com/settings/keys. It's stored in the iOS Keychain
   (`com.goose.swift.claude` / `anthropic-api-key`), device-only.
3. Pick a model from the profile menu (Opus / Sonnet / Haiku). Usage is billed
   to your Anthropic account.

## Must verify on a Mac (could not be done here)

- **Compile.** No Swift toolchain in this environment; check for type errors.
- End-to-end: connect a key, send a prompt, confirm streaming text + tool
  events ("Calling" → "Running" → "Returned"), and a final answer.
- The two-pass tool loop (Claude calls `load_stats` etc., then answers).
- Keychain persistence across app launches; **Sign Out** clears the key.

## Follow-ups (not blocking)

- Rename `OpenAICoachChatModel` → `ClaudeCoachChatModel` and the two file names
  (`OpenAICoach*.swift`) once you can update `project.pbxproj` in Xcode.
- Remove the now-dead OpenAI/Codex auth code: `CodexEmbeddedAuth.swift`,
  `CodexLoginDeviceCode` (in `CodexCoachSupport.swift`), and the
  `codexEmbeddedLoginRequestID` / Codex callback handling in `AppRouter.swift`.
  Left in place to keep the build stable; they're unused now.
- Consider enabling adaptive thinking (`thinking: {type: "adaptive"}`) if you
  want visible reasoning; currently omitted to keep replies fast.
- Unrelated but pending from the security review: disable `UIFileSharingEnabled`
  / `LSSupportsOpeningDocumentsInPlace` in `Info.plist` (see `SECURITY-REVIEW.md`).
