import Defaults
import SwiftUI

struct HeaderView: View {
  @State private var appState = AppState.shared

  let controller: SlideoutController
  @FocusState.Binding var searchFocused: Bool

  var previewPlacement: SlideoutPlacement {
    return controller.placement
  }

  /// The app's own actions move here once the footer menu is stripped, the way
  /// Spotlight keeps its affordances as small trailing glyphs rather than rows.
  private var overflowVisible: Bool {
    ForkStyle.isActive && ForkStyle.chrome != .menu
  }

  var body: some View {
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

        if overflowVisible {
          OverflowMenuView()
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
    .readHeight(appState, into: \.popup.headerHeight)
  }
}

/// Clear / Settings / About / Quit, folded behind one glyph so the list stays
/// content-only. Highlightable from the keyboard: arrowing up off the first row
/// lands here, and Return opens it, the same as clicking.
struct OverflowMenuView: View {
  @Environment(AppState.self) private var appState

  private func runFooterItem(named title: String) {
    guard let item = appState.footer.items.first(where: { $0.title == title }) else { return }
    if item.confirmation != nil, Defaults[.suppressClearAlert] == false {
      item.showConfirmation = true
    } else {
      item.action()
    }
  }

  var body: some View {
    @Bindable var state = appState

    Button {
      appState.overflowMenuOpen.toggle()
    } label: {
      Image(systemName: "ellipsis.circle")
        .foregroundStyle(appState.overflowHighlighted ? Color.accentColor : Color.secondary)
        .padding(3)
        .background(
          Circle()
            .fill(Color.accentColor.opacity(appState.overflowHighlighted ? 0.25 : 0))
        )
    }
    .buttonStyle(.plain)
    .frame(height: 23)
    .accessibilityLabel(Text("more_actions_accessibility_label"))
    .popover(isPresented: $state.overflowMenuOpen, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 2) {
        menuButton("clear") { runFooterItem(named: "clear") }
        Divider().padding(.vertical, 2)
        menuButton("preferences") { appState.openPreferences() }
        menuButton("about") {
          appState.popup.close()
          NSApp.orderFrontStandardAboutPanel(nil)
          NSApp.activate(ignoringOtherApps: true)
        }
        Divider().padding(.vertical, 2)
        menuButton("quit") { NSApp.terminate(nil) }
      }
      .padding(8)
      .frame(minWidth: 160, alignment: .leading)
    }
  }

  private func menuButton(_ key: String, action: @escaping () -> Void) -> some View {
    Button {
      appState.overflowMenuOpen = false
      action()
    } label: {
      Text(LocalizedStringKey(key))
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
  }
}
