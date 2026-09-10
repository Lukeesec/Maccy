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
          if scenePhase == .background {
            // The panel is reused between showings, so a picker left open would
            // still be down the next time it appears -- and an Escape dismissal
            // does not outlive the popup either.
            appState.resetScopePicker()
          }
        }
        // The field drives the picker. A leading "/" is a command: it opens the
        // picker and narrows it as more is typed. Anything else is an ordinary
        // search term, and typing one is how a picker opened from the chevron or
        // Left arrow is dismissed by simply carrying on.
        .onChange(of: searchQuery) {
          appState.syncScopePicker(with: searchQuery)
        }
        // Only reliable way to disable the cursor. allowsHitTesting() does not work
        .offset(y: appState.searchVisible ? 0 : -Popup.searchFieldHeight)
    }
  }
}
