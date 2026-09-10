import AppKit.NSRunningApplication
import Defaults
import KeyboardShortcuts
import Observation

enum PopupState {
  // Default; shortcut will toggle the popup
  case toggle
  // In this mode, every additional press of the main key
  // will cycle to the next item in the paste history list.
  // Releasing the modifier keys will accept selection and close the popup
  case cycle
  // Transition state when the shortcut is first pressed and
  // we don't know whether we are in "toggle" or "cycle" mode.
  case opening
}

@Observable
class Popup {
  static let verticalSeparatorPadding = 6.0
  static let horizontalSeparatorPadding = 6.0
  static let minimumPreviewHeight: CGFloat = 150

  // ---------------------------------------------------------------------------
  // Spotlight geometry (macOS 26 only; pre-Tahoe keeps upstream's numbers, which
  // are tuned for NSVisualEffectView and look wrong at these proportions).
  // ---------------------------------------------------------------------------

  /// Fixed panel width. Spotlight is a wide, short slab rather than a tall column.
  static let panelWidth: CGFloat = 720

  /// Spotlight is a short slab that grows with results rather than a tall column.
  ///
  /// The pre-Tahoe branch stays live: upstream lets the user resize the panel and
  /// writes the new size back to `windowSize` while the app is running.
  static var maxPanelHeight: CGFloat {
    Metrics.shared.isActive ? Metrics.spotlightPanelHeight : Defaults[.windowSize].height
  }

  /// One dominant curve on the panel, rather than a radius derived from the items.
  static var windowCornerRadius: CGFloat { Metrics.shared.windowCornerRadius }

  static var verticalPadding: CGFloat { Metrics.shared.verticalPadding }
  static var horizontalPadding: CGFloat { Metrics.shared.horizontalPadding }

  /// Horizontal inset of a row's selection pill from the panel edge. System lists
  /// never run their selection edge to edge.
  static var rowInset: CGFloat { Metrics.shared.rowInset }

  // The search row is the hero: tall, large type, no competing title.
  static var searchFieldHeight: CGFloat { Metrics.shared.searchFieldHeight }
  static var searchFontSize: CGFloat { Metrics.shared.searchFontSize }
  static var searchIconSize: CGFloat { Metrics.shared.searchIconSize }
  static var searchIconSpacing: CGFloat { Metrics.shared.searchIconSpacing }

  /// Row height follows the row variant.
  static var itemHeight: CGFloat { Metrics.shared.itemHeight }

  static var appIconSize: CGFloat { Metrics.shared.appIconSize }

  /// Radius of the selection pill.
  static var cornerRadius: CGFloat { Metrics.shared.cornerRadius }

  static var sectionHeaderHeight: CGFloat { Metrics.sectionHeaderHeight }

  // Alpha of the semantic tint applied to the glass. NSGlassEffectView takes its
  // cast from whatever sits behind the window, so on a light wallpaper the panel
  // reads light even when the system is in Dark Mode. Tinting toward
  // windowBackgroundColor, which is appearance-aware, re-anchors the panel to
  // Dark/Light while leaving the glass translucency intact.
  static let glassTintAlpha: CGFloat = 0.55

  /// Fill opacity of the selection, by variant.
  static var selectionFillOpacity: CGFloat { Metrics.shared.selectionFillOpacity }

  /// Only upstream's full-bleed bar forces a white label.
  static var selectionUsesInvertedLabel: Bool { Metrics.shared.selectionUsesInvertedLabel }

  var needsResize = false
  var height: CGFloat = 0
  var headerHeight: CGFloat = 0
  var extraTopHeight: CGFloat = 0
  var extraBottomHeight: CGFloat = 0
  var footerHeight: CGFloat = 0

  var minimumHeight: CGFloat {
    // Reserve space for 3 items
    return suitableHeight(for: 3 * Popup.itemHeight)
  }

  private var eventsMonitor: Any?

  private var state: PopupState = .toggle

  init() {
    KeyboardShortcuts.onKeyDown(for: .popup, action: handleFirstKeyDown)
    initEventsMonitor()
  }

  deinit {
    deinitEventsMonitor()
  }

  func initEventsMonitor() {
    guard eventsMonitor == nil else { return }

    self.eventsMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.flagsChanged, .keyDown],
      handler: handleEvent
    )
  }

  func deinitEventsMonitor() {
    guard let eventsMonitor else { return }

    NSEvent.removeMonitor(eventsMonitor)
  }

  func open(height: CGFloat, at popupPosition: PopupPosition = Defaults[.popupPosition]) {
    AppState.shared.appDelegate?.panel.open(height: height, at: popupPosition)
  }

  func reset() {
    state = .toggle
    KeyboardShortcuts.enable(.popup)
  }

  func close() {
    AppState.shared.appDelegate?.panel.close()  // close() calls reset
  }

  func isClosed() -> Bool {
    AppState.shared.appDelegate?.panel.isPresented != true
  }

  func preferredHeight(for newHeight: CGFloat) -> CGFloat {
    var height = newHeight

    var minHeight = self.minimumHeight
    // If the preview is non-empty make sure the window accomodates for it to be visible.
    if AppState.shared.preview.state.isOpen && AppState.shared.navigator.leadSelection != nil {
      minHeight = max(minHeight, Self.minimumPreviewHeight)
    }
    minHeight = max(headerHeight + Self.verticalPadding, minHeight)

    height = max(height, minHeight)
    height = min(height, Self.maxPanelHeight)
    return height
  }

  private func suitableHeight(for historyListHeight: CGFloat) -> CGFloat {
    return historyListHeight + headerHeight + extraTopHeight + extraBottomHeight + footerHeight
  }

  func resize(height: CGFloat) {
    self.height = suitableHeight(for: height)
    AppState.shared.appDelegate?.panel.verticallyResize(to: preferredHeight(for: self.height))
    needsResize = false
  }

  private func handleFirstKeyDown() {
    if isClosed() {
      open(height: height)
      state = .opening
      KeyboardShortcuts.disable(.popup)  // Handle events via eventsMonitor. Re-enable on popup close
      return
    }

    // Maccy was not opened via shortcut. We assume toggle mode and close it
    close()
  }

  private func handleEvent(_ event: NSEvent) -> NSEvent? {
    switch event.type {
    case .keyDown:
      return handleKeyDown(event)
    case .flagsChanged:
      return handleFlagsChanged(event)
    default:
      return event
    }
  }

  private func handleKeyDown(_ event: NSEvent) -> NSEvent? {
    if isHotKeyCode(Int(event.keyCode)) {
      if let item = History.shared.pressedShortcutItem {
        AppState.shared.navigator.select(item: item)
        let modifierFlags = NSEvent.ModifierFlags.currentModifierFlags
        Task { @MainActor in
          AppState.shared.history.select(item, flags: modifierFlags)
        }
        return nil
      }

      if state == .opening {
        state = .cycle
        // Next 'if' will highlight next item and then return nil
      }

      if state == .cycle {
        AppState.shared.navigator.highlightNext(allowCycle: true)
        return nil
      }

      if state == .toggle && isHotKeyModifiers(event.modifierFlags) {
        close()
        return nil
      }
    }

    return event
  }

  private func handleFlagsChanged(_ event: NSEvent) -> NSEvent? {
    // If we are in cycle mode, releasing modifiers triggers a selection
    if state == .cycle && allModifiersReleased(event) {
      let modifierFlags = NSEvent.ModifierFlags.currentModifierFlags
      DispatchQueue.main.async {
        AppState.shared.select(flags: modifierFlags)
      }
      return nil
    }

    // Otherwise if in opening mode, enter toggle mode
    if state == .opening && allModifiersReleased(event) {
      state = .toggle
      return event
    }

    return event
  }

  private func isHotKeyCode(_ keyCode: Int) -> Bool {
    guard let shortcut = KeyboardShortcuts.Name.popup.shortcut else {
      return false
    }

    return shortcut.key?.rawValue == keyCode
  }

  private func isHotKeyModifiers(_ modifiers: NSEvent.ModifierFlags) -> Bool {
    guard let shortcut = KeyboardShortcuts.Name.popup.shortcut else {
      return false
    }

    return modifiers.intersection(.deviceIndependentFlagsMask) ==
      shortcut.modifiers.intersection(.deviceIndependentFlagsMask)
  }

  private func allModifiersReleased(_ event: NSEvent) -> Bool {
    return event.modifierFlags.isDisjoint(with: .deviceIndependentFlagsMask)
  }
}

/// Every metric above, resolved once at first use.
///
/// They derive from `ForkStyle`, which derives from UserDefaults, and a row asks
/// for several of them on every layout pass. None of them can change inside a
/// running process -- the style switcher quits and relaunches Maccy -- so they are
/// computed together the first time one is asked for and cached from then on.
/// `Popup`'s public surface is unchanged; only the storage behind it moved.
private struct Metrics {
  static let shared = Metrics()

  /// Not derived from anything, so they stay plain constants.
  static let spotlightPanelHeight: CGFloat = 560
  static let sectionHeaderHeight: CGFloat = 28

  let isActive: Bool
  let windowCornerRadius: CGFloat
  let verticalPadding: CGFloat
  let horizontalPadding: CGFloat
  let rowInset: CGFloat
  let searchFieldHeight: CGFloat
  let searchFontSize: CGFloat
  let searchIconSize: CGFloat
  let searchIconSpacing: CGFloat
  let itemHeight: CGFloat
  let appIconSize: CGFloat
  let cornerRadius: CGFloat
  let selectionFillOpacity: CGFloat
  let selectionUsesInvertedLabel: Bool

  init() {
    let active = ForkStyle.isActive
    let rowStyle = ForkStyle.rowStyle
    let selectionStyle = ForkStyle.selectionStyle

    isActive = active
    verticalPadding = active ? 8 : 5
    horizontalPadding = active ? 10 : 5
    rowInset = active ? 8 : 0
    searchFieldHeight = active ? 56 : 23
    searchFontSize = active ? 21 : 13
    searchIconSize = active ? 19 : 11
    searchIconSpacing = active ? 12 : 5

    switch rowStyle {
    case .twoLine:
      itemHeight = 52
      appIconSize = 26
    case .oneLine:
      itemHeight = 36
      appIconSize = 18
    case .compact:
      itemHeight = active ? 24 : 22
      appIconSize = 15
    }

    let radius: CGFloat
    if active {
      radius = rowStyle == .twoLine ? 10 : 8
    } else {
      radius = 4
    }
    cornerRadius = radius
    windowCornerRadius = active ? 26 : radius + horizontalPadding

    switch selectionStyle {
    case .pill: selectionFillOpacity = 0.22
    case .neutralPill: selectionFillOpacity = 0.10
    case .bar: selectionFillOpacity = 0.8
    }
    selectionUsesInvertedLabel = selectionStyle == .bar
  }
}
