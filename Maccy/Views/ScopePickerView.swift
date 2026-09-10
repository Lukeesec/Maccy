import SwiftUI

// -----------------------------------------------------------------------------
// Scope token in the search field.
//
// Spotlight narrows its results with a token typed into the field itself
// ("/pdf"), rather than with a dropdown menu or a rail of filters, and the token
// stays visible in the field as a chip once committed. This is that pattern:
//
//   * a dim chevron at the left of the search row teaches the gesture,
//   * Left arrow on an empty query -- or typing "/" -- opens the picker,
//   * Return commits the highlighted scope, which then renders as a chip in
//     front of the query text,
//   * Backspace on an empty query removes the chip again.
//
// Everything here is macOS 26 only. On 14/15 the chevron is never drawn and the
// key handlers all return .ignored, so the field behaves exactly as upstream's.
// -----------------------------------------------------------------------------

/// One row of the scope dropdown.
///
/// The scopes come first, then a divider and the escape hatch into Settings.
/// That row is not decoration: with the per-row actions button gone, the picker
/// and ⌘, are the only ways out of the panel into preferences.
enum ScopePickerRow: Hashable, Identifiable {
  case scope(ForkScope)
  case settings

  var id: Self { self }

  /// Fixed order, written out rather than taken from `ForkScope.allCases`, so the
  /// picker does not depend on the enum's conformances or on its case order.
  static let ordered: [ScopePickerRow] = [
    .scope(.all),
    .scope(.text),
    .scope(.links),
    .scope(.images),
    .scope(.files),
    .settings
  ]

  /// The monospaced token shown at the leading edge of the row.
  var token: String {
    switch self {
    case .scope(let scope): return scope.token
    case .settings: return "/set"
    }
  }

  var titleKey: LocalizedStringKey {
    switch self {
    case .scope(let scope): return scopeTitleKey(scope)
    case .settings: return "scope_settings"
    }
  }
}

/// Display name of a scope. Kept here rather than read off `ForkScope.title` so
/// the string goes through the app's own catalogue like every other label.
private func scopeTitleKey(_ scope: ForkScope) -> LocalizedStringKey {
  switch scope {
  case .all: return "scope_all"
  case .text: return "scope_text"
  case .links: return "scope_links"
  case .images: return "scope_images"
  case .files: return "scope_files"
  }
}

/// The dim chevron at the left end of the search row.
///
/// It is the only thing on screen that hints the scope picker exists, so it is
/// always drawn -- quietly -- and brightens into an accent-tinted pill while the
/// picker is open, the way a menu's own title highlights while it is down.
struct ScopeIndicatorView: View {
  @Environment(AppState.self) private var appState

  private var isOpen: Bool { appState.scopePickerOpen }

  /// Deliberately smaller than the magnifying glass: this is an affordance, not
  /// a peer of the field's own glyph.
  private var glyphSize: CGFloat { max(9, Popup.searchIconSize - 8) }
  private var boxSize: CGFloat { glyphSize + 8 }

  var body: some View {
    Image(systemName: "chevron.left")
      .font(.system(size: glyphSize, weight: .semibold))
      .foregroundStyle(
        isOpen ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary)
      )
      .frame(width: boxSize, height: boxSize)
      .background(
        RoundedRectangle(cornerRadius: 5, style: .continuous)
          .fill(Color.accentColor.opacity(isOpen ? 0.22 : 0))
      )
      .contentShape(Rectangle())
      .onTapGesture {
        appState.toggleScopePicker()
      }
      .animation(.easeInOut(duration: 0.12), value: isOpen)
      .accessibilityLabel(Text("scope_picker_accessibility_label"))
  }
}

/// The committed scope, drawn inline in the search field ahead of the query.
struct ScopeChipView: View {
  let scope: ForkScope

  /// Short enough to sit inside the 56pt search row without crowding the text.
  private static let height: CGFloat = 26
  private static let cornerRadius: CGFloat = 7

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: scope.symbol)
        .font(.system(size: 11, weight: .semibold))
      Text(scopeTitleKey(scope))
        .font(.system(size: 13, weight: .medium))
        .lineLimit(1)
    }
    .foregroundStyle(Color.accentColor)
    .padding(.horizontal, 8)
    .frame(height: Self.height)
    .background(
      RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        .fill(Color.accentColor.opacity(0.18))
    )
    .fixedSize()
    .accessibilityElement(children: .combine)
  }
}

/// The dropdown itself, anchored below the left edge of the search row.
struct ScopePickerView: View {
  @Environment(AppState.self) private var appState

  private static let width: CGFloat = 240
  /// Fixed leading column, so the tokens line up as a column of their own.
  private static let tokenWidth: CGFloat = 52
  private static let rowHeight: CGFloat = 26
  private static let cornerRadius: CGFloat = 12

  var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      ForEach(ScopePickerRow.ordered) { row in
        if row == .settings {
          Divider()
            .padding(.vertical, 4)
        }
        rowView(row)
      }
    }
    .padding(6)
    .frame(width: Self.width, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        .fill(Color(nsColor: .windowBackgroundColor))
        // A dropdown over glass needs to read as its own surface, so it sits a
        // little lighter than the panel rather than disappearing into it.
        .overlay(
          RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.06))
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
    )
    .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
    .fixedSize()
  }

  @ViewBuilder
  private func rowView(_ row: ScopePickerRow) -> some View {
    let highlighted = appState.scopePickerSelection == row

    HStack(spacing: 0) {
      Text(row.token)
        .font(.system(size: 12, weight: .regular, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(width: Self.tokenWidth, alignment: .leading)

      Text(row.titleKey)
        .font(.system(size: 13))
        .foregroundStyle(.primary)
        .lineLimit(1)

      Spacer(minLength: 4)

      if case .scope(let scope) = row, scope == appState.scope {
        Image(systemName: "checkmark")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.secondary)
      }
    }
    .padding(.horizontal, 6)
    .frame(height: Self.rowHeight)
    .background(
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(Color.accentColor.opacity(highlighted ? 0.22 : 0))
    )
    .contentShape(Rectangle())
    .onHover { inside in
      if inside {
        appState.scopePickerSelection = row
      }
    }
    .onTapGesture {
      appState.scopePickerSelection = row
      appState.commitScopePicker()
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(highlighted ? [.isSelected] : [])
  }
}
