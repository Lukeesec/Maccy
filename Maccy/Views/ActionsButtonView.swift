import Defaults
import SwiftUI

/// The single actions affordance, rendered wherever ForkStyle.actions puts it.
///
/// One view for every placement so the keyboard contract is identical: Tab (or
/// Right arrow on an empty query) focuses it, Return opens it, Left arrow or
/// Shift-Tab leaves, and clicking does the same as Return.
struct ActionsButtonView: View {
  /// Actions that only make sense with a row selected are omitted when false.
  var includeItemActions: Bool = true

  @Environment(AppState.self) private var appState

  private var focused: Bool { appState.actionsFocused }

  private var selectedItem: HistoryItemDecorator? {
    appState.navigator.selection.first
  }

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
      appState.actionsFocused = true
      appState.actionsMenuOpen.toggle()
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: 15))
        .foregroundStyle(focused ? Color.accentColor : Color.secondary)
        .padding(3)
        .background(Circle().fill(Color.accentColor.opacity(focused ? 0.25 : 0)))
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("more_actions_accessibility_label"))
    .popover(isPresented: $state.actionsMenuOpen, arrowEdge: .bottom) {
      VStack(alignment: .leading, spacing: 2) {
        if includeItemActions, let item = selectedItem {
          menuButton(item.isPinned ? "history_item_unpin_action" : "history_item_pin_action") {
            appState.history.togglePin(item)
          }
          menuButton("history_item_delete_action") {
            appState.history.delete(item)
          }
          Divider().padding(.vertical, 2)
        }

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
      .frame(minWidth: 180, alignment: .leading)
    }
  }

  private func menuButton(_ key: String, action: @escaping () -> Void) -> some View {
    Button {
      appState.actionsMenuOpen = false
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
