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
        .padding(.trailing, overflowVisible ? 4 : Popup.horizontalPadding)

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
/// content-only.
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
    Menu {
      Button {
        runFooterItem(named: "clear")
      } label: {
        Text(LocalizedStringKey("clear"))
      }

      Divider()

      Button {
        appState.openPreferences()
      } label: {
        Text(LocalizedStringKey("preferences"))
      }

      Button {
        appState.popup.close()
        NSApp.orderFrontStandardAboutPanel(nil)
        NSApp.activate(ignoringOtherApps: true)
      } label: {
        Text(LocalizedStringKey("about"))
      }

      Divider()

      Button {
        NSApp.terminate(nil)
      } label: {
        Text(LocalizedStringKey("quit"))
      }
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .frame(height: 23)
    .accessibilityLabel(Text("more_actions_accessibility_label"))
  }
}
