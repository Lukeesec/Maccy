import AppKit.NSEvent
import KeyboardShortcuts
import Sauce

enum KeyChord: CaseIterable {
  static var pasteKey: Key { pasteMenuItem?.key ?? Key.v }
  static var pasteKeyModifiers: NSEvent.ModifierFlags { pasteMenuItem?.keyEquivalentModifierMask ?? .command }
  private static var pasteMenuItem: NSMenuItem? {
    NSApp.mainMenu?.items
      .flatMap { $0.submenu?.items ?? [] }
      .first { $0.action == #selector(NSText.paste) }
  }

  static var deleteKey: Key? { Sauce.shared.key(shortcut: .delete) }
  static var deleteModifiers: NSEvent.ModifierFlags? { KeyboardShortcuts.Shortcut(name: .delete)?.modifiers }

  static var pinKey: Key? { Sauce.shared.key(shortcut: .pin) }
  static var pinModifiers: NSEvent.ModifierFlags? { KeyboardShortcuts.Shortcut(name: .pin)?.modifiers }

  static var previewKey: Key? { Sauce.shared.key(shortcut: .togglePreview) }
  static var previewModifiers: NSEvent.ModifierFlags? { KeyboardShortcuts.Shortcut(name: .togglePreview)?.modifiers }

  case clearHistory
  case clearHistoryAll
  case clearSearch
  case deleteCurrentItem
  case deleteOneCharFromSearch
  case deleteLastWordFromSearch
  case ignored
  case moveToNext
  case moveToLast
  case moveToPrevious
  case moveToFirst
  case extendToNext
  case extendToLast
  case extendToPrevious
  case extendToFirst
  case openPreferences
  case pinOrUnpin
  case copyCurrentItem
  case focusActions
  case unfocusActions
  case arrowLeft
  case arrowRight
  case openScopePicker
  case closeScopePicker
  case commitScope
  case moveScopeNext
  case moveScopePrevious
  case clearScope
  case selectCurrentItem
  case close
  case togglePreview
  case unknown

  init(_ event: NSEvent?) {
    guard let event, event.type == .keyDown else {
      self = .unknown
      return
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    var key: Key?

    if KeyboardLayout.current.commandSwitchesToQWERTY, modifierFlags.contains(.command) {
      key = Key(QWERTYKeyCode: Int(event.keyCode))
    } else {
      key = Sauce.shared.key(for: Int(event.keyCode))
    }

    guard let key else {
      self = .unknown
      return
    }

    self.init(key, modifierFlags)
  }

  /// Keys the scope dropdown takes over while it is showing.
  ///
  /// This is resolved before the main switch rather than as cases inside it. The
  /// switch is ordered, several of its cases carry `where` clauses, and there is
  /// a modifier catch-all near the bottom that silently swallows anything added
  /// after it -- so a menu that has to win the arrows outright is clearer, and
  /// safer, handled up front.
  private static func scopePickerChord(
    _ key: Key,
    _ modifierFlags: NSEvent.ModifierFlags
  ) -> KeyChord? {
    switch (key, modifierFlags) {
    case (.downArrow, []),
         (.tab, []),
         (.n, [.control]),
         (.j, [.control]):
      return .moveScopeNext
    case (.upArrow, []),
         (.tab, [.shift]),
         (.p, [.control]),
         (.k, [.control]):
      return .moveScopePrevious
    case (.return, _),
         (.keypadEnter, _):
      return .commitScope
    case (.escape, _):
      return .closeScopePicker
    default:
      return nil
    }
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  init(_ key: Key, _ modifierFlags: NSEvent.ModifierFlags) {
    if AppState.shared.scopePickerOpen,
       let chord = KeyChord.scopePickerChord(key, modifierFlags) {
      self = chord
      return
    }

    switch (key, modifierFlags) {
    case (.delete, [.command, .option]):
      self = .clearHistory
    case (.delete, [.command, .option, .shift]):
      self = .clearHistoryAll
    case (.u, [.control]):
      self = .clearSearch
    // Backspace on an empty query deletes the scope chip, the way a token in a
    // Mail or Finder search field is deleted. Guarded on there being a chip to
    // delete, so an ordinary Backspace still reaches the text field untouched.
    // Ahead of the delete-item shortcut, which defaults to ⌥⌫ and so does not
    // collide; a user who rebinds it to a bare Backspace loses it only while a
    // chip is showing and the query is empty.
    case (.delete, []) where ForkStyle.isActive
      && AppState.shared.scope != .all
      && AppState.shared.history.searchQuery.isEmpty:
      self = .clearScope
    case (KeyChord.deleteKey, KeyChord.deleteModifiers):
      self = .deleteCurrentItem
    case (.h, [.control]):
      self = .deleteOneCharFromSearch
    case (.w, [.control]):
      self = .deleteLastWordFromSearch
    case (.downArrow, [.shift]),
         (.n, [.control, .shift]):
      self = AppState.shared.multiSelectionEnabled ? .extendToNext : .moveToNext
    case (.downArrow, []),
         (.n, [.control]),
         (.j, [.control]):
      self = .moveToNext
    case (.downArrow, [.command, .shift]),
         (.downArrow, [.option, .shift]),
         (.n, [.control, .option, .shift]):
      self = AppState.shared.multiSelectionEnabled ? .extendToLast : .moveToLast
    case (.downArrow, _) where modifierFlags.contains(.command) || modifierFlags.contains(.option),
         (.n, [.control, .option]),
         (.pageDown, []):
      self = .moveToLast
    case (.upArrow, [.shift]),
         (.p, [.control, .shift]):
      self = AppState.shared.multiSelectionEnabled ? .extendToPrevious : .moveToPrevious
    case (.upArrow, []),
         (.p, [.control]):
      self = .moveToPrevious
    case (.k, [.control]) where !AppState.shared.navigator.isFirstItemHighlighted:
      // See https://github.com/p0deje/Maccy/issues/1055
      self = .moveToPrevious
    case (.upArrow, [.command, .shift]),
         (.upArrow, [.option, .shift]),
         (.p, [.control, .option, .shift]):
      self = AppState.shared.multiSelectionEnabled ? .extendToFirst : .moveToFirst
    case (.upArrow, _) where modifierFlags.contains(.command) || modifierFlags.contains(.option),
         (.p, [.control, .option]),
         (.pageUp, []):
      self = .moveToFirst
    case (KeyChord.pinKey, KeyChord.pinModifiers):
      self = .pinOrUnpin
    case (.comma, [.command]):
      self = .openPreferences
    // Ctrl+C and Option+C both mirror Enter: copy the highlighted item and close.
    // These must stay above the modifier catch-all further down, which would
    // otherwise classify them as .ignored and pass them to the search field --
    // where Option+C in particular would insert a "ç" rather than doing nothing.
    case (.c, [.control]),
         (.c, [.option]):
      self = .copyCurrentItem
    // Tab is how macOS moves focus between controls, and is all that is left of
    // the actions affordance now that it defaults to no placement at all.
    case (.tab, []):
      self = .focusActions
    case (.tab, [.shift]):
      self = .unfocusActions
    // The arrows are ambiguous by themselves: they belong to the caret whenever
    // there is a query to move through, and only mean "open the preview" or
    // "open the scope picker" on an empty one. Classify them plainly here and
    // let the handler, which can see the query, decide.
    case (.rightArrow, []):
      self = .arrowRight
    case (.leftArrow, []):
      self = .arrowLeft
    // Typing "/" at the start of an empty query opens the scope picker, the way
    // Spotlight narrows with a token. Anywhere else it is just a slash, which is
    // again the handler's call.
    case (.slash, []):
      self = .openScopePicker
    case (.return, _),
         (.keypadEnter, _):
      self = .selectCurrentItem
    case (.escape, _):
      self = .close
    case (KeyChord.previewKey, KeyChord.previewModifiers):
      self = .togglePreview
    case (_, _) where !modifierFlags.isDisjoint(with: [.command, .control, .option]):
      self = .ignored
    default:
      self = .unknown
    }
  }
}
