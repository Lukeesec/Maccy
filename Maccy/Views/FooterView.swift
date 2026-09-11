import Defaults
import KeyboardShortcuts
import SwiftUI

struct FooterView: View {
  @Bindable var footer: Footer

  @Environment(AppState.self) private var appState
  @Environment(ModifierFlags.self) private var modifierFlags
  @Default(.showFooter) private var showFooter
  @State private var showClear = true
  @State private var showClearAll = false

  var clearAllModifiersPressed: Bool {
    let clearModifiers = footer.items[0].shortcuts.first?.modifierFlags ?? []
    let clearAllModifiers = footer.items[1].shortcuts.first?.modifierFlags ?? []
    return !modifierFlags.flags.isEmpty
      && !modifierFlags.flags.isSubset(of: clearModifiers)
      && modifierFlags.flags.isSubset(of: clearAllModifiers)
  }

  var body: some View {
    Group {
      switch ForkStyle.chrome {
      case .menu:
        menuFooter
      case .hintBar:
        HintBarView()
      case .stripped:
        Color.clear.frame(height: 0)
      }
    }
    .readHeight(appState, into: \.popup.footerHeight)
  }

  /// Upstream's selectable Clear / Preferences / About / Quit rows.
  private var menuFooter: some View {
    VStack(spacing: 0) {
      Divider()
        .padding(.horizontal, Popup.horizontalSeparatorPadding)
        .padding(.bottom, Popup.verticalSeparatorPadding)

      ZStack {
        FooterItemView(item: footer.items[0])
          .invisible(!showClear)
        FooterItemView(item: footer.items[1])
          .invisible(!showClearAll)
      }
      .onChange(of: modifierFlags.flags) {
        if clearAllModifiersPressed {
          showClear = false
          showClearAll = true
          footer.items[0].isVisible = false
          footer.items[1].isVisible = true
          if appState.footer.selectedItem == footer.items[0] {
            appState.navigator.select(footerItem: footer.items[1])
          }
        } else {
          showClear = true
          showClearAll = false
          footer.items[0].isVisible = true
          footer.items[1].isVisible = false
          if appState.footer.selectedItem == footer.items[1] {
            appState.navigator.select(footerItem: footer.items[0])
          }
        }
      }

      ForEach(footer.items.suffix(from: 2)) { item in
        FooterItemView(item: item)
      }
    }
    .invisible(!showFooter)
    .frame(maxHeight: showFooter ? nil : 0)
    .padding(.bottom, showFooter ? Popup.verticalPadding : 0)
  }
}

/// A quiet bar of keyboard hints. Instruction, not menu: nothing here is
/// selectable, which is what keeps the list reading as content only.
struct HintBarView: View {
  private var deleteHint: String? {
    KeyboardShortcuts.Shortcut(name: .delete)?.description
  }

  var body: some View {
    HStack(spacing: 14) {
      Spacer(minLength: 0)
      hint("↩", "hint_paste")
      hint("←", "hint_plain_text")
      if let deleteHint {
        hint(deleteHint, "hint_delete")
      }

      if ForkStyle.actions == .hintBar {
        ActionsButtonView()
          .padding(.leading, 2)
      }
    }
    .padding(.horizontal, Popup.rowInset + 8)
    .padding(.top, 6)
    .padding(.bottom, Popup.verticalPadding + 2)
      }

  private func hint(_ keys: String, _ labelKey: String) -> some View {
    HStack(spacing: 4) {
      Text(keys)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
      Text(LocalizedStringKey(labelKey))
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }
  }
}
