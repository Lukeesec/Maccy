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
  private var heroField: some View {
    HStack(spacing: Popup.searchIconSpacing) {
      Image(systemName: "magnifyingglass")
        .font(.system(size: Popup.searchIconSize, weight: .regular))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)

      TextField(placeholder, text: $query)
        .disableAutocorrection(true)
        .lineLimit(1)
        .textFieldStyle(.plain)
        .font(.system(size: Popup.searchFontSize, weight: .regular))
        .onSubmit {
          appState.select(flags: .currentModifierFlags)
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
            appState.select(flags: .currentModifierFlags)
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
