import Foundation

/// Per-request accumulator for a single streamed Claude response. A reference
/// type so the streaming closure can mutate it across events without `inout`.
private final class ClaudeStreamAccumulator {
  /// Visible text produced in this response (appended live to the UI message).
  var assistantText = ""
  /// Tool-use blocks keyed by their content-block index, preserving arrival order.
  var toolUses: [Int: ClaudeToolUse] = [:]
  var stopReason: String?
}

@MainActor
final class OpenAICoachChatModel: ObservableObject {
  @Published private(set) var isSignedIn = false
  @Published private(set) var loginStatus = "Add API key"
  @Published private(set) var modelPreset: CoachModelPreset
  @Published private(set) var messages: [CoachChatMessage] = []
  @Published private(set) var streamState: CoachStreamState = .idle
  @Published private(set) var errorMessage: String?

  private static let modelPresetDefaultsKey = "goose.coach.modelPreset"
  private static let seedPromptText = "What should we look at today?"
  private static let maxToolIterations = 5

  private var apiKey: String?
  private var sendTask: Task<Void, Never>?
  private let client = ClaudeMessagesClient()

  init() {
    let storedRawValue = UserDefaults.standard.string(forKey: Self.modelPresetDefaultsKey)
    modelPreset = storedRawValue.flatMap(CoachModelPreset.init(rawValue:)) ?? .defaultValue
    messages = Self.normalizedPersistedMessages(CoachConversationStore.load())
    if !messages.isEmpty {
      persistConversation()
    }
  }

  deinit {
    sendTask?.cancel()
  }

  /// Loads any stored API key from the Keychain and updates signed-in state.
  func refreshAuth() {
    if let key = ClaudeAPIKeyStore.load() {
      apiKey = key
      isSignedIn = true
      loginStatus = "Connected"
      seedAssistantPromptIfNeeded()
    } else {
      apiKey = nil
      isSignedIn = false
      loginStatus = "Add API key"
    }
  }

  /// Validates, stores (Keychain), and activates an Anthropic API key.
  func signIn(apiKey rawKey: String) {
    let trimmed = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
    errorMessage = nil
    guard !trimmed.isEmpty else {
      errorMessage = ClaudeCoachError.missingAPIKey.localizedDescription
      return
    }
    guard trimmed.hasPrefix("sk-ant-") else {
      errorMessage = "That doesn't look like an Anthropic API key (expected an sk-ant-… key)."
      return
    }
    do {
      try ClaudeAPIKeyStore.save(trimmed)
      apiKey = trimmed
      isSignedIn = true
      loginStatus = "Connected"
      seedAssistantPromptIfNeeded()
    } catch {
      errorMessage = describe(error)
    }
  }

  func selectModelPreset(_ preset: CoachModelPreset) {
    modelPreset = preset
    UserDefaults.standard.set(preset.rawValue, forKey: Self.modelPresetDefaultsKey)
  }

  func startNewConversation() {
    sendTask?.cancel()
    sendTask = nil
    streamState = .idle
    errorMessage = nil
    messages.removeAll()
    CoachConversationStore.clear()
    seedAssistantPromptIfNeeded()
  }

  func signOut() {
    sendTask?.cancel()
    sendTask = nil
    do {
      try ClaudeAPIKeyStore.clear()
    } catch {
      errorMessage = describe(error)
    }
    apiKey = nil
    isSignedIn = false
    loginStatus = "Add API key"
    streamState = .idle
    messages.removeAll()
    CoachConversationStore.clear()
  }

  func cancelStreaming() {
    sendTask?.cancel()
    sendTask = nil
    streamState = .idle
    cancelStreamingMessages()
  }

  func send(
    _ prompt: String,
    healthStore: HealthDataStore,
    appModel: GooseAppModel
  ) {
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty, !streamState.isStreaming else {
      return
    }
    guard let apiKey else {
      isSignedIn = false
      errorMessage = ClaudeCoachError.missingAPIKey.localizedDescription
      return
    }

    let assistantID = UUID()
    let contextualPrompt = contextualPrompt(for: trimmedPrompt)
    messages.append(CoachChatMessage(role: .user, text: trimmedPrompt))
    messages.append(CoachChatMessage(id: assistantID, role: .assistant, text: "", isStreaming: true))
    streamState = .streaming
    errorMessage = nil
    persistConversation()

    sendTask?.cancel()
    sendTask = Task { [weak self] in
      guard let self else {
        return
      }
      do {
        try await streamResponseLoop(
          contextualPrompt: contextualPrompt,
          apiKey: apiKey,
          assistantID: assistantID,
          healthStore: healthStore,
          appModel: appModel
        )
        finishAssistantMessage(assistantID)
        streamState = .idle
      } catch is CancellationError {
        markAssistantMessageCancelled(assistantID)
        streamState = .idle
      } catch where isCancelledError(error) {
        markAssistantMessageCancelled(assistantID)
        streamState = .idle
      } catch {
        let message = describe(error)
        appendAssistantText("\n\(message)", to: assistantID)
        finishAssistantMessage(assistantID)
        errorMessage = message
        streamState = .failed(message)
      }
    }
  }

  /// Drives the Anthropic agentic loop: request → stream → if Claude returned
  /// `tool_use`, run the local tools, append the tool results, and request
  /// again, until Claude produces a final answer (or the iteration cap is hit).
  private func streamResponseLoop(
    contextualPrompt: String,
    apiKey: String,
    assistantID: UUID,
    healthStore: HealthDataStore,
    appModel: GooseAppModel
  ) async throws {
    let activeModelPreset = modelPreset
    var wireMessages: [[String: Any]] = [ClaudeCoachRequestFactory.userMessage(contextualPrompt)]

    for _ in 0..<Self.maxToolIterations {
      let accumulator = ClaudeStreamAccumulator()
      let requestBody = ClaudeCoachRequestFactory.makeRequest(
        messages: wireMessages,
        toolMode: .auto,
        modelPreset: activeModelPreset
      )

      try await client.stream(apiKey: apiKey, body: requestBody) { [weak self] event in
        guard let self else {
          return
        }
        try handle(event, assistantID: assistantID, accumulator: accumulator)
      }

      let orderedToolUses = accumulator.toolUses
        .sorted { $0.key < $1.key }
        .map { $0.value }

      guard accumulator.stopReason == "tool_use", !orderedToolUses.isEmpty else {
        return
      }

      // Reconstruct the assistant turn (text + tool_use blocks) for history.
      var assistantContent: [[String: Any]] = []
      let trimmedText = accumulator.assistantText.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmedText.isEmpty {
        assistantContent.append(["type": "text", "text": accumulator.assistantText])
      }
      for toolUse in orderedToolUses {
        assistantContent.append([
          "type": "tool_use",
          "id": toolUse.id,
          "name": toolUse.name,
          "input": toolInputObject(toolUse.inputJSON),
        ])
      }
      wireMessages.append(["role": "assistant", "content": assistantContent])

      // Execute each tool locally and return the results as a user turn.
      var toolResults: [[String: Any]] = []
      for toolUse in orderedToolUses {
        let output = execute(toolName: toolUse.name, healthStore: healthStore, appModel: appModel)
        updateToolEvent(id: toolUse.id, in: assistantID) { event in
          event.status = "Returned"
          event.resultSummary = summarizeToolOutput(output)
        }
        toolResults.append([
          "type": "tool_result",
          "tool_use_id": toolUse.id,
          "content": output,
        ])
      }
      wireMessages.append(["role": "user", "content": toolResults])
    }

    if isAssistantTextEmpty(assistantID) {
      throw ClaudeCoachError.api("Coach kept requesting tools without a final reply.")
    }
  }

  private func handle(
    _ event: ClaudeStreamEvent,
    assistantID: UUID,
    accumulator: ClaudeStreamAccumulator
  ) throws {
    switch event.type {
    case "message_start", "ping":
      break
    case "content_block_start":
      guard let index = event.payload["index"] as? Int,
            let block = event.payload["content_block"] as? [String: Any] else {
        return
      }
      if block["type"] as? String == "tool_use",
         let id = block["id"] as? String,
         let name = block["name"] as? String {
        accumulator.toolUses[index] = ClaudeToolUse(id: id, name: name, inputJSON: "")
        upsertToolEvent(
          CoachToolEvent(id: id, name: name, status: "Calling", arguments: "", resultSummary: nil),
          in: assistantID
        )
      }
    case "content_block_delta":
      guard let index = event.payload["index"] as? Int,
            let delta = event.payload["delta"] as? [String: Any] else {
        return
      }
      switch delta["type"] as? String {
      case "text_delta":
        if let text = delta["text"] as? String {
          appendAssistantText(text, to: assistantID)
        }
      case "input_json_delta":
        if let partial = delta["partial_json"] as? String,
           var toolUse = accumulator.toolUses[index] {
          toolUse.inputJSON += partial
          accumulator.toolUses[index] = toolUse
          updateToolEvent(id: toolUse.id, in: assistantID) { event in
            event.status = "Preparing"
            event.arguments = toolUse.inputJSON
          }
        }
      default:
        break
      }
    case "content_block_stop":
      guard let index = event.payload["index"] as? Int,
            let toolUse = accumulator.toolUses[index] else {
        return
      }
      updateToolEvent(id: toolUse.id, in: assistantID) { event in
        event.status = "Running"
        event.arguments = toolUse.inputJSON
      }
    case "message_delta":
      if let delta = event.payload["delta"] as? [String: Any],
         let stopReason = delta["stop_reason"] as? String {
        accumulator.stopReason = stopReason
      }
    case "message_stop":
      break
    case "error":
      throw ClaudeCoachError.api(errorMessage(from: event.payload))
    default:
      break
    }
  }

  private func execute(
    toolName: String,
    healthStore: HealthDataStore,
    appModel: GooseAppModel
  ) -> String {
    let payload = CoachLocalToolContext.build(healthStore: healthStore, appModel: appModel)
    let tools = payload["tools"] as? [String: Any] ?? [:]
    let output: Any

    switch toolName {
    case "load_stats", "get_activities", "get_capture_sessions", "get_raw_session_data":
      output = tools[toolName] ?? ["error": "tool_not_available", "tool": toolName]
    case "get_data_gaps":
      output = [
        "readiness": healthStore.metricInputReadinessSummary(),
        "input_next_action": healthStore.metricInputReadinessNextActionSummary(),
        "score_next_action": healthStore.packetDerivedScoreNextActionSummary(),
        "packet_inputs": healthStore.packetInputStatus,
        "packet_scores": healthStore.packetScoreStatus,
        "capture": tools["get_capture_sessions"] ?? [:],
      ]
    default:
      output = ["error": "unknown_tool", "tool": toolName]
    }

    return jsonString(output)
  }

  /// Parses an accumulated tool-input JSON string into an object for the wire
  /// assistant turn. Goose tools take no input, so an empty/invalid string
  /// becomes `{}`.
  private func toolInputObject(_ json: String) -> [String: Any] {
    let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
          let data = trimmed.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return [:]
    }
    return object
  }

  private func appendAssistantText(_ delta: String, to id: UUID) {
    guard let index = messages.firstIndex(where: { $0.id == id }) else {
      return
    }
    messages[index].text += delta
  }

  private func contextualPrompt(for prompt: String) -> String {
    let transcript = recentTranscriptContext(excludingCurrentPrompt: prompt)
    guard !transcript.isEmpty else {
      return prompt
    }
    return """
    Recent Coach conversation context:
    \(transcript)

    Current user message:
    \(prompt)
    """
  }

  private func recentTranscriptContext(excludingCurrentPrompt prompt: String) -> String {
    let turns = messages.compactMap { message -> String? in
      guard !message.isStreaming, !message.isCancelled else {
        return nil
      }
      let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, text != Self.seedPromptText else {
        return nil
      }
      if message.role == .user, text == prompt {
        return nil
      }
      switch message.role {
      case .user:
        return "User: \(text)"
      case .assistant:
        return "Coach: \(text)"
      }
    }
    return boundedContext(from: turns.suffix(12), maxCharacters: 6_000)
  }

  private func boundedContext<S: Sequence>(from turns: S, maxCharacters: Int) -> String where S.Element == String {
    var selected: [String] = []
    var count = 0
    for turn in Array(turns).reversed() {
      let nextCount = count + turn.count + 2
      guard nextCount <= maxCharacters || selected.isEmpty else {
        break
      }
      selected.append(turn)
      count = nextCount
    }
    return selected.reversed().joined(separator: "\n\n")
  }

  private func isAssistantTextEmpty(_ id: UUID) -> Bool {
    guard let message = messages.first(where: { $0.id == id }) else {
      return true
    }
    return message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  private func upsertToolEvent(_ event: CoachToolEvent, in messageID: UUID) {
    guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }) else {
      return
    }
    if let eventIndex = messages[messageIndex].toolEvents.firstIndex(where: { $0.id == event.id }) {
      messages[messageIndex].toolEvents[eventIndex] = event
    } else {
      messages[messageIndex].toolEvents.append(event)
    }
  }

  private func updateToolEvent(
    id: String,
    in messageID: UUID,
    update: (inout CoachToolEvent) -> Void
  ) {
    guard let messageIndex = messages.firstIndex(where: { $0.id == messageID }) else {
      return
    }
    guard let eventIndex = messages[messageIndex].toolEvents.firstIndex(where: { $0.id == id }) else {
      return
    }
    update(&messages[messageIndex].toolEvents[eventIndex])
  }

  private func finishAssistantMessage(_ id: UUID) {
    guard let index = messages.firstIndex(where: { $0.id == id }) else {
      return
    }
    messages[index].isStreaming = false
    if messages[index].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
       messages[index].toolEvents.isEmpty,
       !messages[index].isCancelled {
      messages.remove(at: index)
    }
    persistConversation()
  }

  private func markAssistantMessageCancelled(_ id: UUID) {
    guard let index = messages.firstIndex(where: { $0.id == id }) else {
      return
    }
    messages[index].isStreaming = false
    messages[index].isCancelled = true
    markUnfinishedToolEventsStopped(in: index)
    persistConversation()
  }

  private func cancelStreamingMessages() {
    for index in messages.indices {
      guard messages[index].isStreaming else {
        continue
      }
      messages[index].isStreaming = false
      if messages[index].role == .assistant {
        messages[index].isCancelled = true
        markUnfinishedToolEventsStopped(in: index)
      }
    }
    persistConversation()
  }

  private func markUnfinishedToolEventsStopped(in messageIndex: Int) {
    for eventIndex in messages[messageIndex].toolEvents.indices {
      if messages[messageIndex].toolEvents[eventIndex].status != "Returned" {
        messages[messageIndex].toolEvents[eventIndex].status = "Stopped"
      }
    }
  }

  private func seedAssistantPromptIfNeeded() {
    guard messages.isEmpty else {
      return
    }
    messages.append(
      CoachChatMessage(
        role: .assistant,
        text: Self.seedPromptText
      )
    )
    persistConversation()
  }

  private func errorMessage(from payload: [String: Any]) -> String {
    if let error = payload["error"] as? [String: Any] {
      return error["message"] as? String ?? "\(error)"
    }
    return payload["message"] as? String ?? "Coach stream failed."
  }

  private func summarizeToolOutput(_ output: String) -> String {
    let compact = output
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "  ", with: " ")
    return String(compact.prefix(180))
  }

  private func jsonString(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else {
      return "{\"error\":\"json_encoding_failed\"}"
    }
    return string
  }

  private func persistConversation() {
    CoachConversationStore.save(messages)
  }

  private func describe(_ error: Error) -> String {
    if isCancelledError(error) {
      return "Generation stopped."
    }
    if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
      return description
    }
    return String(describing: error)
  }

  private func isCancelledError(_ error: Error) -> Bool {
    if let urlError = error as? URLError {
      return urlError.code == .cancelled
    }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
  }

  private static func normalizedPersistedMessages(_ storedMessages: [CoachChatMessage]) -> [CoachChatMessage] {
    storedMessages.map { message in
      var normalized = message
      if normalized.isStreaming {
        normalized.isStreaming = false
        normalized.isCancelled = true
      }
      if normalized.isCancelled {
        for index in normalized.toolEvents.indices where normalized.toolEvents[index].status != "Returned" {
          normalized.toolEvents[index].status = "Stopped"
        }
      }
      return normalized
    }
  }
}
