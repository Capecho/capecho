import Carbon
import Foundation

public enum CapechoShortcutAction: String, CaseIterable {
  case capture
  case review
  case wordBook

  var hotKeyID: UInt32 {
    switch self {
    case .capture: 1
    case .review: 2
    case .wordBook: 3
    }
  }

  var title: String {
    switch self {
    case .capture: "Capture"
    case .review: "Review"
    case .wordBook: "Word Book"
    }
  }

  var defaultShortcut: CapechoShortcut {
    switch self {
    case .capture: CapechoShortcut(key: "E", modifiers: ["option"])
    case .review: CapechoShortcut(key: "R", modifiers: ["option"])
    case .wordBook: CapechoShortcut(key: "B", modifiers: ["option"])
    }
  }
}

public struct CapechoShortcut: Equatable {
  public let key: String
  public let keyCode: UInt32
  public let modifiers: [String]
  public let modifierMask: UInt32
  public let display: String

  public init(key: String, modifiers: [String]) {
    let normalizedKey = Self.normalizeKey(key)
    self.key = normalizedKey
    keyCode = Self.keyCode(for: normalizedKey) ?? UInt32(kVK_ANSI_E)
    self.modifiers = Self.normalizeModifiers(modifiers)
    modifierMask = Self.modifierMask(for: self.modifiers)
    display = Self.display(key: normalizedKey, modifiers: self.modifiers)
  }

  public func dictionary(action: CapechoShortcutAction) -> [String: Any] {
    [
      "action": action.rawValue,
      "title": action.title,
      "key": key,
      "modifiers": modifiers,
      "display": display,
    ]
  }

  static func fromDictionary(_ value: Any?, fallback: CapechoShortcut) -> CapechoShortcut {
    guard let dict = value as? [String: Any],
      let key = dict["key"] as? String,
      let modifiers = dict["modifiers"] as? [String],
      Self.keyCode(for: Self.normalizeKey(key)) != nil,
      !Self.normalizeModifiers(modifiers).isEmpty
    else {
      return fallback
    }
    return CapechoShortcut(key: key, modifiers: modifiers)
  }

  public static func canRepresent(key: String) -> Bool {
    keyCode(for: normalizeKey(key)) != nil
  }

  private static func normalizeKey(_ key: String) -> String {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count == 1 {
      return trimmed.uppercased()
    }
    return trimmed
  }

  private static func normalizeModifiers(_ modifiers: [String]) -> [String] {
    let input = Set(modifiers.map { $0.lowercased() })
    return ["control", "option", "shift", "command"].filter { input.contains($0) }
  }

  private static func modifierMask(for modifiers: [String]) -> UInt32 {
    var mask: UInt32 = 0
    if modifiers.contains("control") { mask |= UInt32(controlKey) }
    if modifiers.contains("option") { mask |= UInt32(optionKey) }
    if modifiers.contains("shift") { mask |= UInt32(shiftKey) }
    if modifiers.contains("command") { mask |= UInt32(cmdKey) }
    return mask
  }

  private static func display(key: String, modifiers: [String]) -> String {
    var text = ""
    if modifiers.contains("control") { text += "⌃" }
    if modifiers.contains("option") { text += "⌥" }
    if modifiers.contains("shift") { text += "⇧" }
    if modifiers.contains("command") { text += "⌘" }
    return text + key
  }

  private static func keyCode(for key: String) -> UInt32? {
    keyCodes[key]
  }

  private static let keyCodes: [String: UInt32] = [
    "A": UInt32(kVK_ANSI_A),
    "B": UInt32(kVK_ANSI_B),
    "C": UInt32(kVK_ANSI_C),
    "D": UInt32(kVK_ANSI_D),
    "E": UInt32(kVK_ANSI_E),
    "F": UInt32(kVK_ANSI_F),
    "G": UInt32(kVK_ANSI_G),
    "H": UInt32(kVK_ANSI_H),
    "I": UInt32(kVK_ANSI_I),
    "J": UInt32(kVK_ANSI_J),
    "K": UInt32(kVK_ANSI_K),
    "L": UInt32(kVK_ANSI_L),
    "M": UInt32(kVK_ANSI_M),
    "N": UInt32(kVK_ANSI_N),
    "O": UInt32(kVK_ANSI_O),
    "P": UInt32(kVK_ANSI_P),
    "Q": UInt32(kVK_ANSI_Q),
    "R": UInt32(kVK_ANSI_R),
    "S": UInt32(kVK_ANSI_S),
    "T": UInt32(kVK_ANSI_T),
    "U": UInt32(kVK_ANSI_U),
    "V": UInt32(kVK_ANSI_V),
    "W": UInt32(kVK_ANSI_W),
    "X": UInt32(kVK_ANSI_X),
    "Y": UInt32(kVK_ANSI_Y),
    "Z": UInt32(kVK_ANSI_Z),
    "0": UInt32(kVK_ANSI_0),
    "1": UInt32(kVK_ANSI_1),
    "2": UInt32(kVK_ANSI_2),
    "3": UInt32(kVK_ANSI_3),
    "4": UInt32(kVK_ANSI_4),
    "5": UInt32(kVK_ANSI_5),
    "6": UInt32(kVK_ANSI_6),
    "7": UInt32(kVK_ANSI_7),
    "8": UInt32(kVK_ANSI_8),
    "9": UInt32(kVK_ANSI_9),
    ",": UInt32(kVK_ANSI_Comma),
    ".": UInt32(kVK_ANSI_Period),
    "/": UInt32(kVK_ANSI_Slash),
    ";": UInt32(kVK_ANSI_Semicolon),
    "'": UInt32(kVK_ANSI_Quote),
    "[": UInt32(kVK_ANSI_LeftBracket),
    "]": UInt32(kVK_ANSI_RightBracket),
    "\\": UInt32(kVK_ANSI_Backslash),
    "-": UInt32(kVK_ANSI_Minus),
    "=": UInt32(kVK_ANSI_Equal),
    "`": UInt32(kVK_ANSI_Grave),
  ]
}

public enum CapechoShortcutPreferences {
  public static let changedNotification = Notification.Name("capecho.shortcutsChanged")

  public static func shortcut(for action: CapechoShortcutAction) -> CapechoShortcut {
    CapechoShortcut.fromDictionary(
      UserDefaults.standard.object(forKey: storageKey(for: action)),
      fallback: action.defaultShortcut)
  }

  public static func display(for action: CapechoShortcutAction) -> String {
    shortcut(for: action).display
  }

  public static func allDictionaries() -> [[String: Any]] {
    CapechoShortcutAction.allCases.map { action in shortcut(for: action).dictionary(action: action) }
  }

  public static func validate(
    action: CapechoShortcutAction,
    key: String,
    modifiers: [String]
  ) throws -> CapechoShortcut {
    guard CapechoShortcut.canRepresent(key: key) else {
      throw ShortcutError.unsupportedKey(key)
    }
    let shortcut = CapechoShortcut(key: key, modifiers: modifiers)
    guard !shortcut.modifiers.isEmpty else {
      throw ShortcutError.missingModifier
    }
    if let conflict = conflictingAction(for: shortcut, excluding: action) {
      throw ShortcutError.conflict(conflict.title)
    }
    return shortcut
  }

  public static func store(_ shortcut: CapechoShortcut, for action: CapechoShortcutAction) {
    UserDefaults.standard.set(
      ["key": shortcut.key, "modifiers": shortcut.modifiers],
      forKey: storageKey(for: action))
    NotificationCenter.default.post(name: changedNotification, object: nil)
  }

  private static func conflictingAction(
    for shortcut: CapechoShortcut,
    excluding action: CapechoShortcutAction
  ) -> CapechoShortcutAction? {
    CapechoShortcutAction.allCases.first { other in
      other != action && self.shortcut(for: other).keyCode == shortcut.keyCode
        && self.shortcut(for: other).modifierMask == shortcut.modifierMask
    }
  }

  private static func storageKey(for action: CapechoShortcutAction) -> String {
    "capecho.shortcut.\(action.rawValue)"
  }

  public enum ShortcutError: LocalizedError {
    case unsupportedKey(String)
    case missingModifier
    case conflict(String)

    public var errorDescription: String? {
      switch self {
      case .unsupportedKey(let key):
        "The key '\(key)' is not supported for a global shortcut."
      case .missingModifier:
        "Use at least one modifier key."
      case .conflict(let title):
        "That shortcut is already used by \(title)."
      }
    }

    var code: String {
      switch self {
      case .unsupportedKey: "unsupported_key"
      case .missingModifier: "missing_modifier"
      case .conflict: "shortcut_conflict"
      }
    }
  }
}
