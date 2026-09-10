import Defaults
import KeyboardShortcuts
import SwiftUI

struct ListHeaderView: View {
  @FocusState.Binding var searchFocused: Bool
  @Binding var searchQuery: String

  @Environment(AppState.self) private var appState
  @Environment(\.scenePhase) private var scenePhase

  @Default(.showTitle) private var showTitle

  /// System surfaces never name themselves. Spotlight has no "Spotlight" label, so
  /// the title is suppressed outright once the redesign is active, regardless of
  /// the preference, which still governs the pre-Tahoe layout.
  private var titleVisible: Bool { showTitle && !ForkStyle.isActive }

  var body: some View {
    HStack {
      if titleVisible {
        Text("Maccy")
          .foregroundStyle(.secondary)
          .padding(.leading, 5)
      }

      SearchFieldView(placeholder: "search_placeholder", query: $searchQuery)
        .focused($searchFocused)
        .frame(maxWidth: .infinity)
        .onChange(of: scenePhase) {
          if scenePhase == .background && !searchQuery.isEmpty {
            searchQuery = ""
          }
        }
        // Only reliable way to disable the cursor. allowsHitTesting() does not work
        .offset(y: appState.searchVisible ? 0 : -Popup.searchFieldHeight)
    }
  }
}
