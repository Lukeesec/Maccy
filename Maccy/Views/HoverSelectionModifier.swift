import SwiftUI

private struct HoverSelectionModifier: ViewModifier {
  @Environment(AppState.self) private var appState
  var id: UUID

  /// The rule now lives on the navigator, which owns the remembered hover and is
  /// the only place that can also refuse to *apply* it. See
  /// `NavigationManager.hoverSelectionSuppressed`.
  private var hoverSelectionSuppressed: Bool {
    appState.navigator.hoverSelectionSuppressed
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
