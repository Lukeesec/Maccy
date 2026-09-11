import AppKit
import SwiftData
import SwiftUI

struct ContentView: View {
  @State private var appState = AppState.shared
  @State private var modifierFlags = ModifierFlags()
  @State private var scenePhase: ScenePhase = .background
  /// Drives the entrance animation. System surfaces are placed, not drawn: Spotlight
  /// scales and fades in rather than simply appearing.
  @State private var presented: Bool = false

  @FocusState private var searchFocused: Bool

  @Environment(\.accessibilityReduceMotion) private var reduceMotionEnvironment

  /// The environment value is the one SwiftUI keeps up to date, but this view is
  /// hosted in an NSPanel rather than a scene, so read the workspace flag as well
  /// and take either.
  private var reduceMotion: Bool {
    reduceMotionEnvironment || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// Direct manipulation has to read as instant: the whole open loop has well
  /// under 100ms of budget, and a spring that overshoots spends it announcing
  /// itself. Critically damped, so the panel arrives and stops. Bounce belongs to
  /// gesture-driven motion, not to chrome that appears on a keystroke.
  ///
  /// Under Reduce Motion there is no scale at all, just a short cross-fade.
  private var entranceAnimation: Animation {
    reduceMotion
      ? .easeOut(duration: 0.1)
      : .spring(response: 0.20, dampingFraction: 1.0)
  }

  var body: some View {
    ZStack {
      if #available(macOS 26.0, *) {
        GlassEffectView()
      } else {
        VisualEffectView()
      }

      KeyHandlingView(searchQuery: $appState.history.searchQuery, searchFocused: $searchFocused) {
        VStack(spacing: 0) {
          SlideoutView(controller: appState.preview) {
            HeaderView(
              controller: appState.preview,
              searchFocused: $searchFocused
            )

            VStack(alignment: .leading, spacing: 0) {
              HistoryListView(
                searchQuery: $appState.history.searchQuery,
                searchFocused: $searchFocused
              )

              FooterView(footer: appState.footer)
            }
            .animation(.default.speed(3), value: appState.history.items)
            .animation(
              .default.speed(3),
              value: appState.history.pasteStack?.id
            )
            .padding(.horizontal, Popup.horizontalPadding)
            .onAppear {
              searchFocused = true
            }
            .onMouseMove {
              appState.navigator.isKeyboardNavigating = false
            }
          } slideout: {
            SlideoutContentView()
          }
          .frame(minHeight: 0)
          .layoutPriority(1)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .task {
        try? await appState.history.load()
      }
    }
    .scaleEffect(
      ForkStyle.isActive && !reduceMotion ? (presented ? 1 : 0.965) : 1,
      anchor: .center
    )
    .opacity(ForkStyle.isActive ? (presented ? 1 : 0) : 1)
    .animation(.easeInOut(duration: 0.2), value: appState.searchVisible)
    .onChange(of: scenePhase) {
      // Either direction: the remembered hover names a row in a list that is
      // about to be, or has just been, rebuilt. Left set, the first mouse
      // movement after the popup opens yanks the selection to wherever the
      // pointer happened to be parked last time.
      appState.navigator.forgetHoverSelection()

      if scenePhase == .active {
        withAnimation(entranceAnimation) {
          presented = true
        }
      } else {
        presented = false
        appState.actionsFocused = false
        appState.actionsMenuOpen = false
        // The popup is gone; a scratch edit does not outlive it.
        PreviewEditor.shared.begin(item: nil)
      }
    }
    // Put the caret back in the search field when something outside SwiftUI gave
    // the keyboard up. See AppState.searchRefocusToken for why this cannot just
    // be `searchFocused = true`: the binding already reads true, so assigning it
    // moves nothing. Drop it and re-assert it a runloop turn later, so the focus
    // actually travels from whatever state AppKit left it in.
    .onChange(of: appState.searchRefocusToken) {
      PreviewEditor.shared.isFocused = false
      searchFocused = false
      DispatchQueue.main.async {
        searchFocused = true
      }
    }
    .environment(appState)
    .environment(modifierFlags)
    .environment(\.scenePhase, scenePhase)
    // FloatingPanel is not a scene, so let's implement custom scenePhase..
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) {
      if let window = $0.object as? NSWindow,
         let bundleIdentifier = Bundle.main.bundleIdentifier,
         window.identifier == NSUserInterfaceItemIdentifier(bundleIdentifier) {
        scenePhase = .active
      }
    }
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) {
      if let window = $0.object as? NSWindow,
         let bundleIdentifier = Bundle.main.bundleIdentifier,
         window.identifier == NSUserInterfaceItemIdentifier(bundleIdentifier) {
        scenePhase = .background
      }
    }
  }
}

#Preview {
  ContentView()
    .environment(\.locale, .init(identifier: "en"))
    .modelContainer(Storage.shared.container)
}
