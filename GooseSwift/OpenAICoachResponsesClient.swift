import Foundation
import Security

// Coach now talks to Anthropic's Claude Messages API instead of the ChatGPT
// backend. The file name is kept so the Xcode project file references stay
// intact; everything inside targets `https://api.anthropic.com/v1/messages`.

/// A single Claude `tool_use` block accumulated from a streamed response.
struct ClaudeToolUse: Equatable {
  let id: String
  let name: String
  var inputJSON: String
}

/// One decoded Server-Sent Event from the Messages API stream. The `data:`
/// JSON object always carries a `type` matching the SSE `event:` line.
struct ClaudeStreamEvent {
  let type: String
  let payload: [String: Any]
}

enum ClaudeCoachError: Error, LocalizedError {
  case missingAPIKey
  case invalidURL
  case invalidRequestBody
  case invalidResponse
  case httpStatus(Int, String)
  case keychain(OSStatus)
  case api(String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      return "Add your Anthropic API key first."
    case .invalidURL:
      return "The Claude Messages URL is invalid."
    case .invalidRequestBody:
      return "The Coach request could not be encoded."
    case .invalidResponse:
      return "Claude returned an invalid streaming response."
    case .httpStatus(let status, let body):
      if status == 401 {
        return "Claude rejected the API key (HTTP 401). Check the key and try again."
      }
      return body.isEmpty
        ? "Claude request failed with HTTP \(status)."
        : "Claude request failed with HTTP \(status): \(body)"
    case .keychain(let status):
      return "Keychain operation failed (status \(status))."
    case .api(let message):
      return message
    }
  }
}

/// Stores the user's Anthropic API key in the iOS Keychain. Mirrors the secure
/// storage pattern used for the previous OAuth tokens: a generic-password item
/// scoped to this device, readable after first unlock.
enum ClaudeAPIKeyStore {
  private static let service = "com.goose.swift.claude"
  private static let account = "anthropic-api-key"

  static func load() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess,
          let data = item as? Data,
          let key = String(data: data, encoding: .utf8) else {
      return nil
    }
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  static func save(_ key: String) throws {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = trimmed.data(using: .utf8), !trimmed.isEmpty else {
      throw ClaudeCoachError.missingAPIKey
    }
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    SecItemDelete(base as CFDictionary)
    var add = base
    add[kSecValueData as String] = data
    add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(add as CFDictionary, nil)
    guard status == errSecSuccess else {
      throw ClaudeCoachError.keychain(status)
    }
  }

  static func clear() throws {
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(base as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ClaudeCoachError.keychain(status)
    }
  }
}

enum ClaudeCoachRequestFactory {
  enum ToolMode {
    case auto
    case none
  }

  static func userMessage(_ text: String) -> [String: Any] {
    [
      "role": "user",
      "content": [
        ["type": "text", "text": text],
      ],
    ]
  }

  /// Builds a Messages API request body. The conversation `messages` array is
  /// already in Anthropic wire format (alternating user/assistant turns,
  /// including `tool_use` / `tool_result` blocks for the agentic loop).
  static func makeRequest(
    messages: [[String: Any]],
    toolMode: ToolMode,
    modelPreset: CoachModelPreset
  ) -> [String: Any] {
    var request: [String: Any] = [
      "model": modelPreset.modelID,
      "max_tokens": 4096,
      "system": systemPrompt,
      "messages": messages,
      "stream": true,
    ]
    // Effort is supported on Opus/Sonnet but rejected on Haiku, so only send it
    // when the selected preset opts in.
    if let effort = modelPreset.effort {
      request["output_config"] = ["effort": effort]
    }
    switch toolMode {
    case .auto:
      request["tools"] = tools
      request["tool_choice"] = ["type": "auto"]
    case .none:
      break
    }
    return request
  }

  private static let systemPrompt = """
  You are Goose Coach inside a user-owned WHOOP companion app. Use the available Goose tools before making claims about health, activity, capture coverage, or device state. Call a tool when the answer depends on the user's local metrics rather than answering from memory. Cite tool names inline for metric claims, keep coaching practical, and say when data is missing or stale. Do not diagnose, prescribe, or infer medical conditions. Prefer one concrete next action when the local data is incomplete.
  """

  private static let emptySchema: [String: Any] = [
    "type": "object",
    "properties": [:],
  ]

  private static let tools: [[String: Any]] = [
    [
      "name": "load_stats",
      "description": "Load the current local Goose metric snapshot, readiness status, score summaries, live heart-rate summary, and provenance.",
      "input_schema": emptySchema,
    ],
    [
      "name": "get_activities",
      "description": "Load the current manual activity, activity detection, movement packet, persistence, and route summaries.",
      "input_schema": emptySchema,
    ],
    [
      "name": "get_capture_sessions",
      "description": "Load local capture, packet import, Rust core/parser status, last parsed frame, and device evidence coverage.",
      "input_schema": emptySchema,
    ],
    [
      "name": "get_data_gaps",
      "description": "Load the concrete data gaps and next actions that should block or qualify Coach recommendations.",
      "input_schema": emptySchema,
    ],
  ]
}

struct ClaudeMessagesClient {
  private let endpoint = URL(string: "https://api.anthropic.com/v1/messages")
  private let anthropicVersion = "2023-06-01"

  func stream(
    apiKey: String,
    body: [String: Any],
    onEvent: @MainActor @escaping (ClaudeStreamEvent) throws -> Void
  ) async throws {
    guard let endpoint else {
      throw ClaudeCoachError.invalidURL
    }
    let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedKey.isEmpty else {
      throw ClaudeCoachError.missingAPIKey
    }
    guard JSONSerialization.isValidJSONObject(body) else {
      throw ClaudeCoachError.invalidRequestBody
    }
    let bodyData = try JSONSerialization.data(withJSONObject: body, options: [])

    var request = URLRequest(url: endpoint)
    request.httpMethod = "POST"
    request.setValue(trimmedKey, forHTTPHeaderField: "x-api-key")
    request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
    request.setValue("application/json", forHTTPHeaderField: "content-type")
    request.setValue("text/event-stream", forHTTPHeaderField: "accept")
    request.httpBody = bodyData
    request.timeoutInterval = 180

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ClaudeCoachError.invalidResponse
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      let body = try await readErrorBody(from: bytes)
      throw ClaudeCoachError.httpStatus(httpResponse.statusCode, body)
    }

    var dataLines: [String] = []
    for try await line in bytes.lines {
      try Task.checkCancellation()
      let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
      if trimmedLine.isEmpty {
        try await emit(dataLines: dataLines, onEvent: onEvent)
        dataLines.removeAll()
      } else if trimmedLine.hasPrefix("data:") {
        let value = String(trimmedLine.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
        dataLines.append(value)
      }
      // `event:` and `:` keep-alive comment lines are ignored — the data JSON
      // already carries the event `type`.
    }
    try await emit(dataLines: dataLines, onEvent: onEvent)
  }

  private func emit(
    dataLines: [String],
    onEvent: @MainActor @escaping (ClaudeStreamEvent) throws -> Void
  ) async throws {
    guard !dataLines.isEmpty else {
      return
    }
    for dataText in dataLines where dataText != "[DONE]" {
      guard let data = dataText.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = object["type"] as? String else {
        continue
      }
      try await onEvent(ClaudeStreamEvent(type: type, payload: object))
    }
  }

  private func readErrorBody(from bytes: URLSession.AsyncBytes) async throws -> String {
    var lines: [String] = []
    for try await line in bytes.lines {
      lines.append(line)
      if lines.joined().count > 4000 {
        break
      }
    }
    return lines.joined(separator: "\n")
  }
}
