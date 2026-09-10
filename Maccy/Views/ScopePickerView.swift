import Foundation
import SwiftUI

// -----------------------------------------------------------------------------
// Scope token in the search field.
//
// Spotlight narrows its results with a token typed into the field itself
// ("/pdf"), rather than with a dropdown menu or a rail of filters, and the token
// stays visible in the field as a chip once committed. This is that pattern:
//
//   * a dim chevron at the left of the search row teaches the gesture,
//   * Left arrow on an empty query opens the picker,
//   * typing "/" opens it too, and keeps typing narrowing it: the "/" and
//     everything after it stay in the field, so a slash is still typable and
//     still searchable,
//   * Return commits the highlighted scope, which replaces the "/..." text with
//     a chip in front of the query,
//   * Backspace on an empty query removes the chip again.
//
// The picker is *docked* under the search row rather than floating over the
// list: it is part of the header's layout, so the results move down instead of
// being covered. See ScopePickerView.reservedHeight.
//
// Everything here is macOS 26 only. On 14/15 the chevron is never drawn and the
// key handlers all return .ignored, so the field behaves exactly as upstream's.
// -----------------------------------------------------------------------------

/// One row of the scope picker.
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

  /// The monospaced token shown at the leading edge of the row. The leading
  /// slash is added here rather than stored on ForkScope, whose `token` is the
  /// bare word the parser matches. Without it the scope rows read "text" while
  /// the settings row read "/set", which looked like two different kinds of thing.
  var token: String {
    switch self {
    case .scope(let scope): return "/\(scope.token)"
    case .settings: return "/set"
    }
  }

  var titleKey: LocalizedStringKey {
    switch self {
    case .scope(let scope): return scopeTitleKey(scope)
    case .settings: return "scope_settings"
    }
  }

  /// What the typed command is matched against: the bare token, and the name the
  /// row actually shows. Both, because "/li" and "/lin" name Links by its token
  /// while "/set" and "/sett" name Settings by either -- and a user typing at a
  /// list of words expects the words to match.
  ///
  /// The token comes off `ForkScope` rather than being restated here; only the
  /// settings row, which is not a scope, carries its own.
  private var needles: [String] {
    switch self {
    case .scope(let scope): return [scope.token, scope.title]
    case .settings: return ["set", NSLocalizedString("scope_settings", comment: "")]
    }
  }

  /// True when what has been typed after the "/" is a prefix of this row.
  ///
  /// Prefix rather than substring: a command palette that jumps to "Images" the
  /// moment you type "g" is not predictable, and every token here is short
  /// enough that a prefix is all the typing anyone should have to do.
  func matches(_ needle: String) -> Bool {
    guard !needle.isEmpty else { return true }

    return needles.contains { candidate in
      candidate.range(
        of: needle,
        options: [.caseInsensitive, .diacriticInsensitive, .anchored]
      ) != nil
    }
  }

  /// The rows a typed command leaves showing. Empty means the text names
  /// nothing, which is the caller's cue to close the picker and let the slash be
  /// an ordinary search term.
  static func rows(matching needle: String) -> [ScopePickerRow] {
    let trimmed = needle.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return ordered }

    return ordered.filter { $0.matches(trimmed) }
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

/// The picker itself, docked in its own gutter under the left of the search row.
///
/// It used to be a `.topLeading` overlay on the search row, which drew it *over*
/// the results -- the panel is a fixed-width NSPanel and cannot put a flyout
/// outside its own bounds, so "beside the list" was never available. Docking it
/// into the header's layout instead gives it real space: the list moves down by
/// exactly this much and stays entirely visible, and `Popup.scopePickerHeight`
/// asks the panel for the extra height so a short panel grows rather than
/// squeezing the results out.
struct ScopePickerView: View {
  @Environment(AppState.self) private var appState

  private static let width: CGFloat = 260
  /// Fixed leading column, so the tokens line up as a column of their own.
  private static let tokenWidth: CGFloat = 52
  private static let rowHeight: CGFloat = 26
  private static let rowSpacing: CGFloat = 1
  /// A `Divider` plus the padding it carries above and below.
  private static let dividerHeight: CGFloat = 9
  private static let containerPadding: CGFloat = 6
  private static let cornerRadius: CGFloat = 12

  /// Gap between the search row and the docked picker.
  static let topGap: CGFloat = 6

  private static func panelHeight(rowCount: Int, hasSettings: Bool) -> CGFloat {
    guard rowCount > 0 else { return 0 }

    // The divider is an element of the stack like any row, so it brings a gap of
    // its own with it.
    let hasDivider = hasSettings && rowCount > 1
    let gaps = CGFloat(rowCount - 1 + (hasDivider ? 1 : 0)) * rowSpacing
    return CGFloat(rowCount) * rowHeight
      + gaps
      + (hasDivider ? dividerHeight : 0)
      + containerPadding * 2
  }

  /// Vertical space the docked picker claims in the header while it is open,
  /// gap included.
  ///
  /// Deliberately the height of the *whole* list rather than of the filtered
  /// rows: narrowing "/l" to a single row must not resize the panel under the
  /// typing. The picker shrinks, the gutter does not, and the extra room simply
  /// goes back to the results.
  static let reservedHeight: CGFloat = topGap
    + panelHeight(rowCount: ScopePickerRow.ordered.count, hasSettings: true)

  private var rows: [ScopePickerRow] { appState.scopePickerRows }

  var body: some View {
    VStack(alignment: .leading, spacing: Self.rowSpacing) {
      ForEach(rows) { row in
        if row == .settings && rows.count > 1 {
          Divider()
            .padding(.vertical, 4)
        }
        rowView(row)
      }
    }
    .padding(Self.containerPadding)
    .frame(width: Self.width, alignment: .leading)
    .background(
      RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        .fill(Color(nsColor: .windowBackgroundColor))
        // Docked or not, the picker needs to read as its own surface, so it sits
        // a little lighter than the panel rather than disappearing into it.
        .overlay(
          RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
            .fill(Color.primary.opacity(0.06))
        )
    )
    .overlay(
      RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
    )
    // Lighter than the dropdown's shadow was: this one sits in the panel's own
    // layout rather than floating above the list, and a heavy shadow would
    // claim otherwise.
    .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    .fixedSize()
    .accessibilityElement(children: .contain)
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
