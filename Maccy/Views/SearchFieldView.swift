import SwiftUI

struct SearchFieldView: View {
  var placeholder: LocalizedStringKey
  @Binding var query: String

  @Environment(AppState.self) private var appState

  var body: some View {
    ZStack {
      // On macOS 26 the field sits directly on the glass, like Spotlight.
      // Pre-Tahoe keeps the filled, bordered box it was designed around.
      if #available(macOS 26.0, *) {
        EmptyView()
      } else {
        RoundedRectangle(cornerRadius: Popup.cornerRadius, style: .continuous)
          .fill(Color.secondary)
          .opacity(0.1)
          .frame(height: Popup.searchFieldHeight)
      }

      HStack(spacing: Popup.searchIconSpacing) {
        Image(systemName: "magnifyingglass")
          .font(.system(size: Popup.searchIconSize, weight: .medium))
          .foregroundStyle(.secondary)
          .padding(.leading, 5)
          .accessibilityHidden(true)

        TextField(placeholder, text: $query)
          .disableAutocorrection(true)
          .lineLimit(1)
          .textFieldStyle(.plain)
          .font(.system(size: Popup.searchFontSize))
          .onSubmit {
            appState.select(flags: .currentModifierFlags)
          }

        if !query.isEmpty {
          Button {
            query = ""
          } label: {
            Image(systemName: "xmark.circle.fill")
              .font(.system(size: Popup.searchIconSize))
              .foregroundStyle(.tertiary)
              .padding(.trailing, 5)
          }
          .buttonStyle(.plain)
          .accessibilityLabel(Text("search_clear_accessibility_label"))
        }
      }
    }
    .frame(height: Popup.searchFieldHeight)
  }
}

#Preview {
  return List {
    SearchFieldView(placeholder: "search_placeholder", query: .constant(""))
    SearchFieldView(placeholder: "search_placeholder", query: .constant("search"))
  }
  .frame(width: 300)
  .environment(\.locale, .init(identifier: "en"))
}
