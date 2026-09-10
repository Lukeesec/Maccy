import SwiftUI

private struct HoverSelectionModifier: ViewModifier {
  @Environment(AppState.self) private var appState
  var id: UUID

  /// Hovering must not retarget the row while the preview is open.
  ///
  /// The preview is opened deliberately for one item, and the pointer has to
  /// travel across the list to reach it. Every row it crosses on the way was
  /// changing the selection, so by the time the click landed the preview was
  /// showing a different item and the editor had been reset out from under the
  /// edit. Auto-open is off in this fork, so an open preview means the user
  /// asked for it: treat it as a focused mode.
  private var hoverSelectionSuppressed: Bool {
    ForkStyle.isActive && appState.preview.state.isOpen
  }

  func body(content: Content) -> some View {
    content.onHover { hovering in
      if hovering, !hoverSelectionSuppressed {
        if !appState.navigator.isKeyboardNavigating && !appState.navigator.isMultiSelectInProgress {
          appState.navigator.selectWithoutScrolling(id: id)
        } else {
          appState.navigator.hoverSelectionWhileKeyboardNavigating = id
        }
      }
    }
  }
}

extension View {
  func hoverSelectionId(_ id: UUID) -> some View {
    modifier(HoverSelectionModifier(id: id))
  }
}
