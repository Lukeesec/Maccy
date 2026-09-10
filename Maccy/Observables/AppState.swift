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

  /// True when focus has moved off the list onto the actions control, so it can
  /// draw itself focused and answer Return.
  var actionsFocused: Bool = false
  /// Drives the actions popover, so Return and a click do the same thing.
  var actionsMenuOpen: Bool = false

  // MARK: - Scope

  /// The scope the history is filtered to, rendered as a chip in the search
  /// field. It lives on History, which owns the filtering, so setting it here
  /// re-runs the query rather than leaving two copies of the truth around.
  var scope: ForkScope {
    get { history.scope }
    set { history.scope = newValue }
  }

  /// Whether the scope dropdown is showing. While it is, it owns the arrows,
  /// Return and Escape -- a menu takes those from whatever is behind it.
  var scopePickerOpen: Bool = false

  /// Row the scope dropdown has highlighted. Meaningless while it is closed.
  var scopePickerSelection: ScopePickerRow = .scope(.all)

  @MainActor
  func openScopePicker() {
    guard ForkStyle.isActive, !scopePickerOpen else { return }
    // Open on what is already committed, so Return with no movement is a no-op
    // rather than a silent reset to "All items".
    scopePickerSelection = .scope(scope)
    scopePickerOpen = true
  }

  func closeScopePicker() {
    scopePickerOpen = false
  }

  @MainActor
  func toggleScopePicker() {
    if scopePickerOpen {
      closeScopePicker()
    } else {
      openScopePicker()
    }
  }

  /// Moves the highlight, wrapping at both ends the way a menu does.
  func moveScopePickerSelection(by delta: Int) {
    let rows = ScopePickerRow.ordered
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
    scopePickerOpen = false

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
