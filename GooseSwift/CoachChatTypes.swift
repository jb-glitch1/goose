import Foundation

enum CoachStreamState: Equatable {
  case idle
  case streaming
  case failed(String)

  var isStreaming: Bool {
    if case .streaming = self {
      return true
    }
    return false
  }
}

struct CoachToolEvent: Identifiable, Equatable, Codable {
  let id: String
  var name: String
  var status: String
  var arguments: String
  var resultSummary: String?
}

struct CoachChatMessage: Identifiable, Equatable, Codable {
  enum Role: Equatable, Codable {
    case user
    case assistant
  }

  let id: UUID
  let role: Role
  var text: String
  var toolEvents: [CoachToolEvent]
  var isStreaming: Bool
  var isCancelled: Bool
  let createdAt: Date

  init(
    id: UUID = UUID(),
    role: Role,
    text: String,
    toolEvents: [CoachToolEvent] = [],
    isStreaming: Bool = false,
    isCancelled: Bool = false,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.role = role
    self.text = text
    self.toolEvents = toolEvents
    self.isStreaming = isStreaming
    self.isCancelled = isCancelled
    self.createdAt = createdAt
  }
}

enum CoachModelPreset: String, CaseIterable, Identifiable {
  case opusHigh
  case sonnetBalanced
  case haikuFast

  var id: String { rawValue }

  static let defaultValue: CoachModelPreset = .opusHigh

  var title: String {
    switch self {
    case .opusHigh:
      return "Opus 4.8 · High"
    case .sonnetBalanced:
      return "Sonnet 4.6 · Balanced"
    case .haikuFast:
      return "Haiku 4.5 · Fast"
    }
  }

  var modelID: String {
    switch self {
    case .opusHigh:
      return "claude-opus-4-8"
    case .sonnetBalanced:
      return "claude-sonnet-4-6"
    case .haikuFast:
      return "claude-haiku-4-5"
    }
  }

  /// Effort is sent only for models that accept it. Opus and Sonnet support the
  /// `output_config.effort` control; Haiku rejects it, so it stays `nil`.
  var effort: String? {
    switch self {
    case .opusHigh:
      return "high"
    case .sonnetBalanced:
      return "medium"
    case .haikuFast:
      return nil
    }
  }
}

enum CoachConversationStore {
  private static let defaultsKey = "goose.coach.conversation.v1"
  private static let maxPersistedMessages = 80

  static func load() -> [CoachChatMessage] {
    guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
      return []
    }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return (try? decoder.decode([CoachChatMessage].self, from: data)) ?? []
  }

  static func save(_ messages: [CoachChatMessage]) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let persisted = Array(messages.suffix(maxPersistedMessages))
    guard let data = try? encoder.encode(persisted) else {
      return
    }
    UserDefaults.standard.set(data, forKey: defaultsKey)
  }

  static func clear() {
    UserDefaults.standard.removeObject(forKey: defaultsKey)
  }
}
