import AppKit
import Defaults
import Foundation
import Settings
import SwiftUI

@Observable
class AppState: Sendable {
  static let shared = AppState(history: History.shared, footer: Footer())

  let multiSelectionEnabled = false

  var appDelegate: AppDelegate?
  var popup: Popup
  var history: History
  var footer: Footer
  var navigator: NavigationManager
  var preview: SlideoutController

  var searchVisible: Bool {
    if !Defaults[.showSearch] { return false }
    switch Defaults[.searchVisibility] {
    case .always: return true
    case .duringSearch: return !history.searchQuery.isEmpty
    }
  }

  var menuIconText: String {
    var title = history.unpinnedItems.first?.text.shortened(to: 100)
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    title.unicodeScalars.removeAll(where: CharacterSet.newlines.contains)
    return title.shortened(to: 20)
  }

  private let about = About()
  private var settingsWindowController: SettingsWindowController?

  init(history: History, footer: Footer) {
    self.history = history
    self.footer = footer
    popup = Popup()
    navigator = NavigationManager(history: history, footer: footer)
    preview = SlideoutController(
      onContentResize: { contentWidth in
        Defaults[.windowSize].width = contentWidth
      },
      onSlideoutResize: { previewWidth in
        Defaults[.previewWidth] = previewWidth
      })
    preview.contentWidth = ForkStyle.isActive ? Popup.panelWidth : Defaults[.windowSize].width
    preview.slideoutWidth = Defaults[.previewWidth]
  }

  /// Bumped whenever something outside SwiftUI has taken the keyboard and the
  /// search field has to be put back.
  ///
  /// The preview is an `NSTextView`: it takes first responder behind SwiftUI's
  /// back, and giving it up again with `makeFirstResponder(nil)` leaves the
  /// *window* as first responder while SwiftUI's `@FocusState` still reads true.
  /// Assigning true to a binding that already holds true moves nothing, so focus
  /// never came back -- and with no responder, `onKeyPress` stops firing and every
  /// key in the popup goes dead, Escape included. That is the lock-up.
  ///
  /// A counter rather than a Bool so that two requests in a row are two events,
  /// and so the observer never has to reset it. ContentView owns the FocusState
  /// and watches this.
  private(set) var searchRefocusToken: Int = 0

  /// Ask ContentView to re-assert focus on the search field.
  func refocusSearch() {
    searchRefocusToken &+= 1
  }

  /// True when focus has moved off the list onto the actions control, so it can
  /// draw itself focused and answer Return.
  var actionsFocused: Bool = false
  /// Drives the actions popover, so Return and a click do the same thing.
  var actionsMenuOpen: Bool = false

  /// The search field stays the real first responder so typing always searches,
  /// but the fork also needs to know whether arrows have moved the user's
  /// *keyboard context* into the history list. Left is contextual: from the
  /// search row it opens scopes/settings; from a history row it opens the
  /// one-shot plain-text action.
  var historyNavigationActive: Bool = false

  /// The history row currently presenting its one-shot plain-text action.
  /// Keeping the identity here makes the popover mutually exclusive across
  /// recycled list rows and lets Return/Escape operate it from KeyHandlingView.
  var plainTextActionItemID: UUID?

  func focusSearchRow() {
    historyNavigationActive = false
    plainTextActionItemID = nil
    if ForkStyle.isActive {
      // Logical focus and painted selection must agree. Leaving the first
      // history row selected here made the first Down look broken: it changed
      // context, but highlighted the row that was already highlighted.
      navigator.select()
    }
  }

  func focusHistoryRow() {
    historyNavigationActive = true
    plainTextActionItemID = nil
  }

  @discardableResult
  func dismissPlainTextAction() -> Bool {
    guard plainTextActionItemID != nil else { return false }
    plainTextActionItemID = nil
    return true
  }

  func openPlainTextAction() {
    guard ForkStyle.isActive, historyNavigationActive,
          let item = navigator.leadHistoryItem else { return }
    closeScopePicker()
    plainTextActionItemID = item.id
  }

  // MARK: - Scope

  /// The scope the history is filtered to, rendered as a chip in the search
  /// field. It lives on History, which owns the filtering, so setting it here
  /// re-runs the query rather than leaving two copies of the truth around.
  var scope: ForkScope {
    get { history.scope }
    set { history.scope = newValue }
  }

  /// Whether the scope picker is showing. While it is, it owns the arrows,
  /// Return and Escape -- a menu takes those from whatever is behind it.
  var scopePickerOpen: Bool = false

  /// Row the scope picker has highlighted. Meaningless while it is closed.
  var scopePickerSelection: ScopePickerRow = .scope(.all)

  /// True when the picker is being driven by a "/..." command typed into the
  /// field, rather than opened from the chevron or Left arrow.
  ///
  /// The difference matters at both ends: only a command picker filters its rows
  /// from the query, and only a command picker has text to take back out of the
  /// field when the scope is committed.
  var scopePickerIsCommand: Bool = false

  /// Set when Escape dismisses a command picker. The "/..." is still sitting in
  /// the field at that point, so without this the next keystroke would open the
  /// picker straight back up and Escape would read as broken.
  private var scopeCommandDismissed: Bool = false

  /// What has been typed after the leading "/".
  ///
  /// Read straight off the query rather than mirrored into a property of its
  /// own: the field is the only place this text exists, and a second copy is a
  /// second thing to keep in step.
  var scopePickerFilter: String {
    guard scopePickerIsCommand else { return "" }

    let query = history.searchQuery
    guard query.hasPrefix("/") else { return "" }

    return String(query.dropFirst())
  }

  /// The rows the picker is currently showing.
  var scopePickerRows: [ScopePickerRow] {
    ScopePickerRow.rows(matching: scopePickerFilter)
  }

  @MainActor
  func openScopePicker(asCommand: Bool = false) {
    // The popover is anchored to the search row's chevron. With that row hidden
    // it would have no valid visual source while still swallowing menu keys.
    guard ForkStyle.isActive, searchVisible, !scopePickerOpen else { return }

    scopePickerIsCommand = asCommand
    // Open on what is already committed, so Return with no movement is a no-op
    // rather than a silent reset to "All items". A command picker re-points this
    // at its first match immediately afterwards.
    scopePickerSelection = .scope(scope)
    scopePickerOpen = true
  }

  func closeScopePicker() {
    scopePickerIsCommand = false

    guard scopePickerOpen else { return }

    scopePickerOpen = false
  }

  /// Back out of the preview: drop its focus, take the scope picker down with it,
  /// close the pane, and hand the keyboard back to the search field.
  ///
  /// Returns false when there was nothing to leave, so Escape can go on meaning
  /// "close the popup".
  ///
  /// One function rather than two copies because it is reached from two different
  /// layers on purpose. The normal route is SwiftUI's `onKeyPress`; the event
  /// monitor calls it as well, because `onKeyPress` only fires while something
  /// inside the panel is first responder, and the whole class of bug this guards
  /// against is the preview leaving nothing as first responder at all. Escape has
  /// to work when the rest of the keyboard does not.
  @MainActor
  @discardableResult
  func leavePreview() -> Bool {
    guard PreviewEditor.shared.isFocused || preview.state.isOpen else { return false }

    PreviewEditor.shared.isFocused = false
    closeScopePicker()
    if preview.state.isOpen {
      preview.togglePreview()
    }
    refocusSearch()
    return true
  }

  /// Escape: the picker goes away and the typed text is left exactly as it is.
  @MainActor
  func dismissScopePicker() {
    if scopePickerIsCommand {
      scopeCommandDismissed = true
    }

    closeScopePicker()
  }

  /// Forget everything about the picker, including an Escape dismissal. Called
  /// when the popup goes away, which is the one moment the typed "/..." stops
  /// being the user's current train of thought.
  func resetScopePicker() {
    scopeCommandDismissed = false
    closeScopePicker()
  }

  @MainActor
  func toggleScopePicker() {
    if scopePickerOpen {
      dismissScopePicker()
    } else {
      openScopePicker()
    }
  }

  /// The single place the typed query is turned into picker state. Called on
  /// every change of the search field.
  ///
  /// A leading "/" is a command: it opens the picker and narrows it as more is
  /// typed. Anything else is a search term -- including a "/" that names no row,
  /// because a slash is a perfectly ordinary thing to want to search for and
  /// must never become un-typable.
  @MainActor
  func syncScopePicker(with query: String) {
    guard ForkStyle.isActive else { return }

    guard query.hasPrefix("/") else {
      // The command is gone: Backspace took the slash, or the field was cleared.
      scopeCommandDismissed = false
      // A picker the command opened goes with it. So does one opened from the
      // chevron or Left arrow the moment there is a query, which is how typing
      // has always dismissed it -- but an empty query leaves that one alone.
      if scopePickerIsCommand || !query.isEmpty {
        closeScopePicker()
      }
      return
    }

    // Escape said no. Leave it closed until the "/" itself goes away.
    guard !scopeCommandDismissed else { return }

    let rows = ScopePickerRow.rows(matching: String(query.dropFirst()))
    guard !rows.isEmpty else {
      closeScopePicker()
      return
    }

    if scopePickerOpen {
      scopePickerIsCommand = true
    } else {
      openScopePicker(asCommand: true)
      // openScopePicker refuses while the search row is hidden.
      guard scopePickerOpen else { return }
    }

    // Keep the highlight on something that is actually on screen.
    if !rows.contains(scopePickerSelection) {
      scopePickerSelection = rows[0]
    }
  }

  /// Moves the highlight, wrapping at both ends the way a menu does, through the
  /// rows the command has left showing rather than through all of them.
  func moveScopePickerSelection(by delta: Int) {
    let rows = scopePickerRows
    guard !rows.isEmpty else { return }
    guard let index = rows.firstIndex(of: scopePickerSelection) else {
      scopePickerSelection = rows[0]
      return
    }

    let count = rows.count
    scopePickerSelection = rows[((index + delta) % count + count) % count]
  }

  @MainActor
  func commitScopePicker() {
    let row = scopePickerSelection
    let wasCommand = scopePickerIsCommand
    closeScopePicker()

    // The "/..." the palette was driven by is not a search term. Committing
    // takes it back out and puts the chip there instead, leaving the caret on an
    // empty query and ready for a real one.
    if wasCommand, history.searchQuery.hasPrefix("/") {
      history.searchQuery = ""
    }

    switch row {
    case .scope(let newScope):
      scope = newScope
    case .settings:
      // Same call as the footer's Preferences row and ⌘,. The settings window
      // taking key closes the panel on its own, via FloatingPanel.resignKey.
      openPreferences()
    }
  }

  /// Removes the chip, which is what Backspace on an empty query means.
  @MainActor
  func clearScope() {
    guard scope != .all else { return }
    scope = .all
  }

  @MainActor
  func select(flags modifierFlags: NSEvent.ModifierFlags) {
    if !navigator.selection.isEmpty {
      if navigator.isMultiSelectInProgress {
        navigator.isManualMultiSelect = false
        history.startPasteStack(selection: &navigator.selection, flags: modifierFlags)
      } else {
        history.select(navigator.selection.first, flags: modifierFlags)
      }
    } else if let item = footer.selectedItem {
      // TODO: Use item.suppressConfirmation, but it's not updated!
      if item.confirmation != nil, Defaults[.suppressClearAlert] == false {
        item.showConfirmation = true
      } else {
        item.action()
      }
    } else {
      Clipboard.shared.copyInMaccy(history.searchQuery)
      history.searchQuery = ""
    }
  }

  /// Return in the Tahoe UI is an explicit paste action, independent of the
  /// global "Paste automatically" preference. The formatting preference still
  /// supplies the normal mode; modified Return keeps the configurable upstream
  /// shortcuts, and Return while the row action is open chooses its advertised
  /// plain-text paste.
  @MainActor
  func activateSelection(flags modifierFlags: NSEvent.ModifierFlags) {
    if let itemID = plainTextActionItemID,
       let item = navigator.leadHistoryItem,
       item.id == itemID {
      paste(item, removeFormatting: true)
      return
    }

    let meaningfulFlags = modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.capsLock, .numericPad, .function])
    if ForkStyle.isActive, meaningfulFlags.isEmpty,
       let item = navigator.leadHistoryItem {
      paste(item, removeFormatting: Defaults[.removeFormattingByDefault])
    } else {
      select(flags: modifierFlags)
    }
  }

  /// The fork's C shortcuts remain copy-only even though Return is now an
  /// explicit paste. The formatting preference still applies globally.
  @MainActor
  func copySelection() {
    if let item = navigator.leadHistoryItem {
      history.copy(item, removeFormatting: Defaults[.removeFormattingByDefault])
    } else {
      select(flags: [])
    }
  }

  @MainActor
  func paste(_ item: HistoryItemDecorator, removeFormatting: Bool) {
    plainTextActionItemID = nil
    history.paste(item, removeFormatting: removeFormatting)
  }

  @MainActor
  func togglePin() {
    withTransaction(Transaction()) {
      navigator.selection.forEach { _, item in
        history.togglePin(item)
      }
    }
  }

  @MainActor
  func removePasteStack() {
    history.interruptPasteStack()
    navigator.highlightFirst()
  }

  @MainActor
  func deleteSelection() {
    guard let leadItem = navigator.leadHistoryItem else { return }
    let nextUnselectedItem = history.visibleItems.nearest(to: leadItem) { !$0.isSelected }

    withTransaction(Transaction()) {
      navigator.selection.forEach { _, item in
        history.delete(item)
      }
      navigator.select(item: nextUnselectedItem)
    }
  }

  func openAbout() {
    about.openAbout(nil)
  }

  @MainActor
  func openPreferences() { // swiftlint:disable:this function_body_length
    if settingsWindowController == nil {
      let generalTitle = NSLocalizedString("Title", tableName: "GeneralSettings", comment: "")
      let storageTitle = NSLocalizedString("Title", tableName: "StorageSettings", comment: "")
      let appearanceTitle = NSLocalizedString("Title", tableName: "AppearanceSettings", comment: "")
      let pinsTitle = NSLocalizedString("Title", tableName: "PinsSettings", comment: "")
      let ignoreTitle = NSLocalizedString("Title", tableName: "IgnoreSettings", comment: "")
      let advancedTitle = NSLocalizedString("Title", tableName: "AdvancedSettings", comment: "")
      let toolbarTitles = [generalTitle, storageTitle, appearanceTitle, pinsTitle, ignoreTitle, advancedTitle]
      let titleAttributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]
      let titleWidth = toolbarTitles.reduce(CGFloat.zero) {
        $0 + ($1 as NSString).size(withAttributes: titleAttributes).width
      }
      let toolbarItemSpacing: CGFloat = 24
      let toolbarEdgeSpacing: CGFloat = 40
      let toolbarWidth = titleWidth + CGFloat(toolbarTitles.count) * toolbarItemSpacing + toolbarEdgeSpacing
      let minimumWidth = max(500, ceil(toolbarWidth))
      settingsWindowController = SettingsWindowController(
        panes: [
          Settings.Pane(
            identifier: Settings.PaneIdentifier.general,
            title: generalTitle,
            toolbarIcon: NSImage.gearshape!
          ) {
            GeneralSettingsPane()
              .frame(minWidth: minimumWidth)
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.storage,
            title: storageTitle,
            toolbarIcon: NSImage.externaldrive!
          ) {
            StorageSettingsPane()
              .frame(minWidth: minimumWidth)
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.appearance,
            title: appearanceTitle,
            toolbarIcon: NSImage.paintpalette!
          ) {
            AppearanceSettingsPane()
              .frame(minWidth: minimumWidth)
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.pins,
            title: pinsTitle,
            toolbarIcon: NSImage.pincircle!
          ) {
            PinsSettingsPane()
              .environment(self)
              .modelContainer(Storage.shared.container)
              .frame(minWidth: minimumWidth)
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.ignore,
            title: ignoreTitle,
            toolbarIcon: NSImage.nosign!
          ) {
            IgnoreSettingsPane()
              .frame(minWidth: minimumWidth)
          },
          Settings.Pane(
            identifier: Settings.PaneIdentifier.advanced,
            title: advancedTitle,
            toolbarIcon: NSImage.gearshape2!
          ) {
            AdvancedSettingsPane()
              .frame(minWidth: minimumWidth)
          }
        ]
      )
    }
    settingsWindowController?.show()
    settingsWindowController?.window?.orderFrontRegardless()
  }

  func quit() {
    NSApp.terminate(self)
  }
}
