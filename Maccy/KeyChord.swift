import AppKit.NSEvent
import Carbon.HIToolbox
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
    case (.rightArrow, []):
      return .closeScopePicker
    case (.escape, _):
      return .closeScopePicker
    default:
      return nil
    }
  }

  /// True when the event is Command+C, Ctrl+C or Option+C, read off the hardware
  /// key code.
  ///
  /// All three, because "the Alt key" is not a fixed thing: on a PC-layout
  /// keyboard the key printed Alt sits where Command does and macOS reports it as
  /// Command, so a user pressing what they call Alt+C is sending ⌘C. Rather than
  /// guess which one a given keyboard produces, accept every modifier that can
  /// plausibly be under that finger.
  ///
  /// Note this takes ⌘C away from the search field: with a scope chip and query
  /// selected, ⌘C copies the highlighted history item rather than the query text.
  /// That is the intended trade in a clipboard popup.
  ///
  /// Read off the key code rather than through the chord table because Option+C
  /// produces a character ("ç") and is consumed as text input before the table
  /// ever sees it -- which is why Ctrl+C worked and Option+C did not.
  static func isCopyShortcut(_ event: NSEvent?) -> Bool {
    guard let event, event.type == .keyDown, Int(event.keyCode) == kVK_ANSI_C else { return false }

    let flags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    return flags == [.command] || flags == [.control] || flags == [.option]
  }

  /// True when the event is the physical Escape key.
  ///
  /// Read straight off the key code rather than through `KeyChord`, which
  /// classifies Escape differently depending on what else is open and is
  /// therefore exactly the wrong thing to ask when the question is "how do I get
  /// out of here". 53 is Escape on every layout.
  static func isEscape(_ event: NSEvent?) -> Bool {
    guard let event, event.type == .keyDown else { return false }

    // Both, because this is the one key that has to work when everything else
    // has gone wrong: the hardware code, and the layout table as a backstop.
    // (Sauce's Key is String-backed, so its rawValue is not a key code.)
    let keyCode = Int(event.keyCode)
    return keyCode == kVK_Escape || Sauce.shared.key(for: keyCode) == .escape
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
    // Command+C, Ctrl+C and Option+C copy the highlighted item and close without
    // pasting. See isCopyShortcut for why all three. These must stay above the
    // modifier catch-all further down, which would otherwise classify them as
    // .ignored and pass them to the search field -- where Option+C in particular
    // would insert a "ç" rather than doing nothing. They also sit above the
    // configurable preview shortcut, so a user who binds preview to one of these
    // loses it here.
    case (.c, [.command]),
         (.c, [.control]),
         (.c, [.option]):
      self = .copyCurrentItem
    // Tab is how macOS moves focus between controls, and is all that is left of
    // the actions affordance now that it defaults to no placement at all.
    case (.tab, []):
      self = .focusActions
    case (.tab, [.shift]):
      self = .unfocusActions
    // The arrows are contextual: while editing a query Left remains a caret key,
    // while history navigation uses Left for the plain-text action and Right for
    // preview. Classify them plainly here and let the handler decide from state.
    case (.rightArrow, []):
      self = .arrowRight
    case (.leftArrow, []):
      self = .arrowLeft
    // "/" is deliberately *not* classified here. It is a real character that has
    // to land in the field: the scope picker is opened by the text, not by the
    // keystroke, so that typing carries on narrowing it and so that a slash the
    // picker cannot name stays an ordinary search term. See
    // AppState.syncScopePicker.
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
