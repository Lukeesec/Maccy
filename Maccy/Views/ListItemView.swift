import Defaults
import SwiftUI

enum SelectionAppearance {
  case none
  case topConnection
  case bottomConnection
  case topBottomConnection

  func rect(cornerRadius: CGFloat) -> some Shape {
    var cornerRadii = RectangleCornerRadii()
    switch self {
    case .none:
      cornerRadii.topLeading = cornerRadius
      cornerRadii.topTrailing = cornerRadius
      cornerRadii.bottomLeading = cornerRadius
      cornerRadii.bottomTrailing = cornerRadius
    case .topConnection:
      cornerRadii.bottomLeading = cornerRadius
      cornerRadii.bottomTrailing = cornerRadius
    case .bottomConnection:
      cornerRadii.topLeading = cornerRadius
      cornerRadii.topTrailing = cornerRadius
    case .topBottomConnection:
      break
    }
    return .rect(cornerRadii: cornerRadii)
  }
}

struct ListItemView<Title: View, ID: Hashable>: View {
  var id: ID
  var selectionId: UUID
  var appIcon: ApplicationImage?
  var image: NSImage?
  var accessoryImage: NSImage?
  var attributedTitle: AttributedString?
  /// Secondary metadata line: source app, time, kind. Two-line rows only.
  var subtitle: String?
  var shortcuts: [KeyShortcut]
  var isSelected: Bool
  var selectionIndex: Int?
  var help: LocalizedStringKey?
  var selectionAppearance: SelectionAppearance = .none
  /// History rows opt in; footer and pin rows do not.
  var showsActions: Bool = false
  // Complete description used when the row's visual content is hidden from accessibility.
  var accessibilityLabel: String = ""
  @ViewBuilder var title: () -> Title

  @Default(.showApplicationIcons) private var showIcons
  @Environment(AppState.self) private var appState
  @Environment(ModifierFlags.self) private var modifierFlags

  // Use the same selection number for the visible badge and accessibility value.
  private var displaySelectionIndex: String? {
    selectionIndex.map { "\($0 + 1)" }
  }

  private var twoLine: Bool { ForkStyle.rowStyle == .twoLine && subtitle != nil && image == nil }

  /// The ⌘n badges are a power-user affordance Apple would not surface by default.
  /// The shortcuts keep working; only the badge is hidden once the chrome is stripped.
  private var shortcutsVisible: Bool { !ForkStyle.isActive || ForkStyle.chrome == .menu }

  private var leadingInset: CGFloat { ForkStyle.isActive ? Popup.rowInset + 8 : 4 }
  private var trailingInset: CGFloat { ForkStyle.isActive ? Popup.rowInset + 8 : 10 }

  var body: some View {
    HStack(spacing: 0) {
      if showIcons, let appIcon {
        VStack {
          Spacer(minLength: 0)
          AppImageView(appImage: appIcon, size: NSSize(width: Popup.appIconSize, height: Popup.appIconSize))
          Spacer(minLength: 0)
        }
        .padding(.leading, leadingInset)
        .padding(.vertical, 5)
      } else {
        Spacer().frame(width: leadingInset)
      }

      Spacer()
        .frame(width: showIcons ? (ForkStyle.isActive ? 10 : 5) : (ForkStyle.isActive ? 0 : 10))

      if let accessoryImage {
        Image(nsImage: accessoryImage)
          .accessibilityIdentifier("copy-history-item")
          .accessibilityHidden(true)
          .padding(.trailing, 5)
          .padding(.vertical, 5)
      }

      if let image {
        Image(nsImage: image)
          .accessibilityIdentifier("copy-history-item")
          .accessibilityHidden(true)
          .padding(.trailing, 5)
          .padding(.vertical, 5)
      } else if twoLine, let subtitle {
        VStack(alignment: .leading, spacing: 2) {
          ListItemTitleView(attributedTitle: attributedTitle, title: title)
            .accessibilityHidden(true)
          Text(subtitle)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .accessibilityHidden(true)
        }
        .padding(.trailing, 5)
      } else {
        ListItemTitleView(attributedTitle: attributedTitle, title: title)
          .accessibilityHidden(true)
          .padding(.trailing, 5)
      }

      Spacer()

      HStack(spacing: 5) {
        if let displaySelectionIndex {
          Text(displaySelectionIndex)
            .font(.caption)
            .frame(minWidth: 10, alignment: .center)
            .padding(3)
            .background(
              Color.secondary.opacity(isSelected ? 0.5 : 0.8),
              in: Capsule()
            )
            .foregroundStyle(Color.white)
            .accessibilityHidden(true)
        }

        if showsActions, isSelected, ForkStyle.actions == .rowTrailing {
          ActionsButtonView()
        }

        if !shortcuts.isEmpty && shortcutsVisible {
          ZStack(alignment: .trailing) {
            ForEach(shortcuts) { shortcut in
              let visible = shortcut.isVisible(shortcuts, modifierFlags.flags)
              KeyboardShortcutView(shortcut: shortcut)
                .opacity(visible ? 1 : 0)
                .accessibilityHidden(true)
                .frame(width: visible ? nil : 0)
            }
          }
        }
      }
      .padding(.trailing, trailingInset)
    }
    .frame(minHeight: Popup.itemHeight)
    .id(id)
    .frame(maxWidth: .infinity, alignment: .leading)
    .foregroundStyle(isSelected && Popup.selectionUsesInvertedLabel ? Color.white : Color.primary)
    .background(selectionBackground)
    .modifier(BarSelectionClip(active: ForkStyle.selectionStyle == .bar, appearance: selectionAppearance))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(Text(accessibilityLabel))
    .accessibilityAddTraits(isSelected ? .isSelected : [])
    .accessibilityValue(Text(displaySelectionIndex ?? ""))
    .hoverSelectionId(selectionId)
    .help(help ?? "")
  }

  @ViewBuilder
  private var selectionBackground: some View {
    if isSelected {
      switch ForkStyle.selectionStyle {
      case .bar:
        Color.accentColor.opacity(Popup.selectionFillOpacity)
      case .pill:
        selectionAppearance.rect(cornerRadius: Popup.cornerRadius)
          .fill(Color.accentColor.opacity(Popup.selectionFillOpacity))
          .padding(.horizontal, Popup.rowInset)
      case .neutralPill:
        selectionAppearance.rect(cornerRadius: Popup.cornerRadius)
          .fill(Color.primary.opacity(Popup.selectionFillOpacity))
          .padding(.horizontal, Popup.rowInset)
      }
    } else {
      // macOS 26 broke hovering if no background is present.
      // The slight opacity white background is a workaround.
      Color.white.opacity(0.001)
    }
  }
}

/// Upstream clipped every row to the selection shape. That is only correct for the
/// full-bleed bar; an inset pill must not clip the row's own content.
private struct BarSelectionClip: ViewModifier {
  let active: Bool
  let appearance: SelectionAppearance

  func body(content: Content) -> some View {
    if active {
      content.clipShape(appearance.rect(cornerRadius: Popup.cornerRadius))
    } else {
      content
    }
  }
}
