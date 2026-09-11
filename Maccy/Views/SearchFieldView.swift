import SwiftUI

struct SearchFieldView: View {
  var placeholder: LocalizedStringKey
  @Binding var query: String

  @Environment(AppState.self) private var appState

  var body: some View {
    if ForkStyle.isActive {
      heroField
    } else {
      legacyField
    }
  }

  /// Spotlight's search row: the field is the hero. No box, no border, large type,
  /// sitting directly on the glass with the glyph as the only ornament.
  ///
  /// The scope lives in the row rather than beside it: a chevron at the far left
  /// that opens the picker, and, once a scope is committed, a chip in front of
  /// the query text that the caret types after and Backspace deletes.
  ///
  /// The picker itself is not drawn here. It used to hang off this row as a
  /// `.topLeading` overlay, which put it straight over the results; it is now
  /// docked in the header below the row, where it has space of its own. See
  /// `HeaderView` and `ScopePickerView`.
  private var heroField: some View {
    HStack(spacing: Popup.searchIconSpacing) {
      HStack(spacing: 6) {
        ScopeIndicatorView()

        Image(systemName: "magnifyingglass")
          .font(.system(size: Popup.searchIconSize, weight: .regular))
          .foregroundStyle(.secondary)
          .accessibilityHidden(true)
      }

      HStack(spacing: 8) {
        if appState.scope != .all {
          ScopeChipView(scope: appState.scope)
            .transition(.opacity)
        }

        TextField(placeholder, text: $query)
          .disableAutocorrection(true)
          .lineLimit(1)
          .textFieldStyle(.plain)
          .font(.system(size: Popup.searchFontSize, weight: .regular))
          .onSubmit {
            appState.activateSelection(flags: .currentModifierFlags)
          }
      }

      if !query.isEmpty {
        Button {
          query = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .font(.system(size: 15))
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("search_clear_accessibility_label"))
      }
    }
    .frame(height: Popup.searchFieldHeight)
    .animation(.easeInOut(duration: 0.12), value: appState.scope)
  }

  /// Upstream's filled, bordered field, kept for pre-Tahoe.
  private var legacyField: some View {
    ZStack {
      RoundedRectangle(cornerRadius: Popup.cornerRadius, style: .continuous)
        .fill(Color.secondary)
        .opacity(0.1)
        .frame(height: Popup.searchFieldHeight)

      HStack {
        Image(systemName: "magnifyingglass")
          .frame(width: 11, height: 11)
          .padding(.leading, 5)
          .opacity(0.8)
          .accessibilityHidden(true)

        TextField(placeholder, text: $query)
          .disableAutocorrection(true)
          .lineLimit(1)
          .textFieldStyle(.plain)
          .onSubmit {
            appState.activateSelection(flags: .currentModifierFlags)
          }

        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .frame(width: 11, height: 11)
              .padding(.trailing, 5)
          }
          .buttonStyle(.plain)
          .opacity(0.9)
          .accessibilityLabel(Text("search_clear_accessibility_label"))
        }
      }
    }
    .frame(height: Popup.searchFieldHeight)
  }
}
