import Sauce
import Defaults
import SwiftUI

struct KeyHandlingView<Content: View>: View { // swiftlint:disable:this type_body_length
  @Binding var searchQuery: String
  @FocusState.Binding var searchFocused: Bool
  @ViewBuilder let content: () -> Content

  @Environment(AppState.self) private var appState

  /// True when the preview genuinely owns the keyboard.
  ///
  /// `PreviewEditor.isFocused` is set in one place and cleared in several, and if
  /// it is ever left true with no editable pane on screen then Up and Down go
  /// dead with nothing on screen to explain why. Treat focus as real only while
  /// the pane is open on an item it will actually render as a field, and repair
  /// the flag when it is not.
  @MainActor
  private func previewHoldsKeys() -> Bool {
    guard PreviewEditor.shared.isFocused else { return false }

    guard appState.preview.state.isOpen,
          PreviewEditor.isEditable(appState.navigator.leadHistoryItem) else {
      PreviewEditor.shared.isFocused = false
      return false
    }

    return true
  }

  var body: some View {
    content()
      .onKeyPress { _ in
        // Unfortunately, key presses don't allow access to
        // key code and don't properly work with multiple inputs,
        // so pressing ⌘, on non-English layout doesn't open
        // preferences. Stick to NSEvent to fix this behavior.
        let event = NSApp.currentEvent

        if searchFocused {
          // Ignore input when candidate window is open
          // https://stackoverflow.com/questions/73677444/how-to-detect-the-candidate-window-when-using-japanese-keyboard
          if let inputClient = NSApp.keyWindow?.firstResponder as? NSTextInputClient,
             inputClient.hasMarkedText() {
            return .ignored
          }
        }

        // Escape gets out of the preview, unconditionally.
        //
        // Deliberately ahead of KeyChord and of every guard below. KeyChord
        // reclassifies Escape as the scope picker's Escape whenever the picker
        // thinks it is open, and the bug this fixes is precisely that some other
        // piece of state disagrees about who owns the key -- so nothing here may
        // depend on that state being consistent. Read the raw key code, drop the
        // focus, take the picker down with it, hand the field back. A second
        // Escape then closes the popup, as it always has.
        // Copy is checked first and off the key code: Option+C produces a
        // character and was being eaten as text input before the chord table saw
        // it, which is why Ctrl+C worked and Option+C did not.
        if KeyChord.isCopyShortcut(event) {
          appState.select(flags: [])
          return .handled
        }

        // Escape when the preview is open at all, not merely when it believes it
        // has focus. The reported lock-up is precisely the case where that flag
        // disagrees with reality, so it must not be the thing Escape depends on.
        //
        // On macOS 26 the event monitor usually gets here first; this stays as
        // the path for the pre-Tahoe build, and as a backstop.
        if KeyChord.isEscape(event), appState.leavePreview() {
          return .handled
        }

        switch KeyChord(event) {
        case .clearHistory:
          if let item = appState.footer.items.first(where: { $0.title == "clear" }),
             item.confirmation != nil,
             let suppressConfirmation = item.suppressConfirmation {
            if suppressConfirmation.wrappedValue {
              item.action()
            } else {
              item.showConfirmation = true
            }
            return .handled
          } else {
            return .ignored
          }
        case .clearHistoryAll:
          if let item = appState.footer.items.first(where: { $0.title == "clear_all" }),
             item.confirmation != nil,
             let suppressConfirmation = item.suppressConfirmation {
            if suppressConfirmation.wrappedValue {
              item.action()
            } else {
              item.showConfirmation = true
            }
            return .handled
          } else {
            return .ignored
          }
        case .clearSearch:
          searchQuery = ""
          // ⌃U empties the field, and the chip is part of the field.
          if ForkStyle.isActive {
            appState.clearScope()
          }
          return .handled
        case .deleteCurrentItem:
          if appState.navigator.pasteStackSelected {
            appState.removePasteStack()
          } else {
            appState.deleteSelection()
          }
          return .handled
        case .deleteOneCharFromSearch:
          searchFocused = true
          _ = searchQuery.popLast()
          return .handled
        case .deleteLastWordFromSearch:
          searchFocused = true
          let newQuery = searchQuery.split(separator: " ").dropLast().joined(separator: " ")
          if newQuery.isEmpty {
            searchQuery = ""
          } else {
            searchQuery = "\(newQuery) "
          }

          return .handled
        case .moveToNext:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }

          // While the preview has focus the arrows are caret keys. Moving the
          // list selection out from under an open draft would discard it. Only
          // while it really has focus, though: a stale flag must not be allowed
          // to disable list navigation.
          guard !previewHoldsKeys() else {
            return .ignored
          }

          appState.navigator.highlightNext()
          return .handled
        case .moveToLast:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }

          appState.navigator.highlightLast()
          return .handled
        case .moveToPrevious:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }

          // See .moveToNext.
          guard !previewHoldsKeys() else {
            return .ignored
          }

          appState.navigator.highlightPrevious()
          return .handled
        case .moveToFirst:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }

          appState.navigator.highlightFirst()
          return .handled
        case .extendToNext:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }
          guard AppState.shared.multiSelectionEnabled else {
            return .ignored
          }
          appState.navigator.extendHighlightToNext()
          return .handled
        case .extendToLast:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }
          guard AppState.shared.multiSelectionEnabled else {
            return .ignored
          }
          appState.navigator.extendHighlightToLast()
          return .handled
        case .extendToPrevious:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }
          guard AppState.shared.multiSelectionEnabled else {
            return .ignored
          }
          appState.navigator.extendHighlightToPrevious()
          return .handled
        case .extendToFirst:
          guard NSApp.characterPickerWindow == nil else {
            return .ignored
          }
          guard AppState.shared.multiSelectionEnabled else {
            return .ignored
          }
          appState.navigator.extendHighlightToFirst()
          return .handled
        case .openPreferences:
          appState.openPreferences()
          return .handled
        case .pinOrUnpin:
          appState.togglePin()
          return .handled
        case .selectCurrentItem where appState.actionsFocused,
             .copyCurrentItem where appState.actionsFocused:
          appState.actionsMenuOpen = true
          return .handled
        case .focusActions:
          // .rowTrailing was retired; only placements that actually draw a
          // control may take focus.
          guard ForkStyle.isActive,
                ForkStyle.actions == .searchRow || ForkStyle.actions == .hintBar else {
            return .ignored
          }
          appState.actionsFocused = true
          return .handled
        case .unfocusActions:
          guard appState.actionsFocused else { return .ignored }
          appState.actionsFocused = false
          appState.actionsMenuOpen = false
          return .handled
        // "/" is not handled here at all. It has to reach the field, so that the
        // text is what drives the picker: see AppState.syncScopePicker, which
        // opens it on a leading slash, narrows it as more is typed, and lets go
        // again the moment the text names no row.
        case .moveScopeNext:
          appState.moveScopePickerSelection(by: 1)
          return .handled
        case .moveScopePrevious:
          appState.moveScopePickerSelection(by: -1)
          return .handled
        case .commitScope:
          appState.commitScopePicker()
          return .handled
        case .closeScopePicker:
          // Escape takes the picker down and leaves whatever was typed exactly
          // where it is -- including a "/..." that would otherwise reopen it on
          // the very next keystroke.
          appState.dismissScopePicker()
          return .handled
        case .clearScope:
          appState.clearScope()
          return .handled
        case .arrowRight:
          // Right arrow opens the editable preview and puts focus in it. The
          // caret wins whenever there is a query to move through, and the
          // preview keeps the key once it has focus.
          guard ForkStyle.isActive, searchQuery.isEmpty, !appState.scopePickerOpen,
                !PreviewEditor.shared.isFocused else {
            return .ignored
          }
          guard let item = appState.navigator.leadHistoryItem else { return .ignored }

          NSLog(
            "MaccySelection Right lead=%@ preview=%@ focused=%@",
            item.id.uuidString,
            String(describing: appState.preview.state),
            PreviewEditor.shared.isFocused.description
          )

          if !appState.preview.state.isOpen {
            appState.preview.togglePreview()
          }
          PreviewEditor.shared.begin(item: item)
          // Focusing an item the pane renders read-only would strand isFocused
          // at true with no field on screen, which silently disables Up/Down.
          guard PreviewEditor.isEditable(appState.navigator.leadHistoryItem) else {
            return .handled
          }
          PreviewEditor.shared.isFocused = true
          return .handled
        case .arrowLeft:
          // Left arrow walks back out of whatever the right arrow walked into,
          // and only opens the scope picker once there is nothing left to leave.
          // The draft is deliberately left alone: leaving the preview is not
          // discarding the edit.
          if PreviewEditor.shared.isFocused {
            // Not leavePreview(): Left arrow steps out of the *editor* and leaves
            // the pane showing. Clearing the flag is what asks for the keyboard
            // back -- see PreviewEditor.isFocused.
            PreviewEditor.shared.isFocused = false
            return .handled
          }
          if appState.actionsFocused {
            appState.actionsFocused = false
            appState.actionsMenuOpen = false
            return .handled
          }
          guard ForkStyle.isActive, searchQuery.isEmpty, !appState.scopePickerOpen else {
            return .ignored
          }
          appState.openScopePicker()
          return .handled
        case .copyCurrentItem:
          // Pass empty flags deliberately. .currentModifierFlags would still carry
          // .control at this point, and HistoryItemAction maps .control to .unknown,
          // which returns early and copies nothing. Empty flags take the same path
          // as an unmodified Return: close, then copy.
          appState.select(flags: [])
          return .handled
        case .selectCurrentItem:
          appState.select(flags: .currentModifierFlags)
          return .handled
        // Escape out of the preview is handled above, before KeyChord runs.
        case .close:
          appState.popup.close()
          return .handled
        case .togglePreview:
          appState.preview.togglePreview()
          return .handled
        default:
          ()
        }

        if let item = appState.history.pressedShortcutItem {
          appState.navigator.select(item: item)
          Task {
            try? await Task.sleep(for: .milliseconds(50))
            appState.history.select(item, flags: .currentModifierFlags)
          }
          return .handled
        }

        return .ignored
      }
  }
}
