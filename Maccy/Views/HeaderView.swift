import AppKit
import Defaults
import SwiftUI

struct HeaderView: View {
  @State private var appState = AppState.shared

  let controller: SlideoutController
  @FocusState.Binding var searchFocused: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotionEnvironment

  var previewPlacement: SlideoutPlacement {
    return controller.placement
  }

  /// Only one placement puts the actions control in the search row.
  private var actionsInSearchRow: Bool {
    ForkStyle.isActive && ForkStyle.actions == .searchRow
  }

  /// The panel is hosted in an NSPanel rather than a scene, so read the
  /// workspace flag as well as the environment value and take either. Same
  /// reasoning as `ContentView`.
  private var reduceMotion: Bool {
    reduceMotionEnvironment || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// The gutter opening is chrome appearing on a keystroke, so it matches the
  /// panel's own entrance: critically damped, arrives and stops. Bounce belongs
  /// to gesture-driven motion.
  private var dockAnimation: Animation {
    reduceMotion
      ? .easeOut(duration: 0.1)
      : .spring(response: 0.20, dampingFraction: 1.0)
  }

  private var scopePickerDocked: Bool {
    ForkStyle.isActive && appState.scopePickerOpen && appState.searchVisible
  }

  var body: some View {
    // The picker is docked *under* the search row rather than drawn over the
    // list. It is a sibling of the row inside the header, so it takes real
    // layout space: the results move down by exactly its height and stay
    // visible. `Popup.scopePickerHeight` carries the same number into the
    // panel's height arithmetic, so a short panel grows to make room rather
    // than squeezing the list out -- and `readHeight` stays on the search row
    // alone so the picker is never counted twice.
    VStack(alignment: .leading, spacing: 0) {
      searchRow
        .readHeight(appState, into: \.popup.headerHeight)

      if scopePickerDocked {
        ScopePickerView()
          // Lines the picker up under the chevron: the search row is inset by
          // the header's padding and again by ListHeaderView's own.
          .padding(.leading, Popup.horizontalPadding * 2)
          .padding(.trailing, Popup.horizontalPadding)
          .padding(.top, ScopePickerView.topGap)
          .transition(.opacity)
      }
    }
    .animation(dockAnimation, value: scopePickerDocked)
    // Belt and braces: the picker no longer overlaps the list, but it is still
    // the header's business to sit above it if anything ever does.
    .zIndex(1)
  }

  private var searchRow: some View {
    HStack(alignment: .top, spacing: 0) {
      HStack(alignment: .center, spacing: 0) {
        ListHeaderView(
          searchFocused: $searchFocused,
          searchQuery: $appState.history.searchQuery
        )
        .padding(.horizontal, Popup.horizontalPadding)

        // The preview toggle is dropped once the redesign is active: a system
        // surface does not put a window-management control in its search row.
        // The shortcut still toggles the preview.
        if !ForkStyle.isActive {
          ToolbarButton {
            controller.togglePreview()
          } label: {
            Image(
              systemName: previewPlacement == .right
                ? "sidebar.left" : "sidebar.right"
            )
          }
          .shortcutKeyHelp(
            name: .togglePreview,
            key: controller.state.isOpen ? "ClosePreview" : "OpenPreview",
            tableName: "PreviewItemView",
            replacementKey: "previewKey"
          )
          .padding(.trailing, Popup.horizontalPadding)
        }

        if actionsInSearchRow {
          ActionsButtonView()
            .frame(height: 23)
            .padding(.trailing, Popup.horizontalPadding)
        }
      }
      .opacity(appState.searchVisible ? 1 : 0)
      .accessibilityHidden(!appState.searchVisible)
      .layoutPriority(1)
    }
    .padding(.top, Popup.verticalPadding)
    .padding(.horizontal, ForkStyle.isActive ? Popup.horizontalPadding : 10)
    .animation(.default.speed(3), value: appState.navigator.leadSelection)
    .background(.clear)
    .frame(maxHeight: !appState.searchVisible ? 0 : nil, alignment: .top)
  }
}
