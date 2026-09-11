import Foundation
import SwiftUI

@Observable
class NavigationManager { // swiftlint:disable:this type_body_length
  private var history: History
  private var footer: Footer

  init(history: History, footer: Footer) {
    self.history = history
    self.footer = footer
  }

  var selection: Selection<HistoryItemDecorator> = Selection() {
    willSet {
      selection.forEach { _, item in item.selectionIndex = -1 }
      newValue.forEach { index, item in item.selectionIndex = index }
    }
  }

  var scrollTarget: UUID?
  var leadSelection: UUID? {
    if let item = leadHistoryItem {
      return item.id
    }
    if let footerItem = footer.selectedItem {
      return footerItem.id
    }
    return history.pasteStack?.id
  }
  private(set) var leadHistoryItem: HistoryItemDecorator? {
    didSet {
      guard oldValue?.id != leadHistoryItem?.id else { return }

      // Announce the visual selection change, keeping repeated navigation updates concise.
      if let item = leadHistoryItem {
        announceForAccessibility {
          var parts = [item.hasImage ? NSLocalizedString("history_item_image_accessibility_generic", comment: "") : item.title]
          if let application = item.application {
            parts.append(application)
          }
          if item.isPinned {
            parts.append(NSLocalizedString("history_item_pinned_accessibility_value", comment: ""))
          }
          return parts.joined(separator: ", ")
        }
      }

      let preview = AppState.shared.preview
      if leadHistoryItem != nil {
        preview.resetAutoOpenSuppression()
        preview.startAutoOpen()
      } else {
        preview.cancelAutoOpen()
      }
    }
  }

  var pasteStackSelected: Bool {
    return leadSelection != nil && leadSelection == history.pasteStack?.id
  }

  var isManualMultiSelect: Bool = false
  var isMultiSelectInProgress: Bool {
    return isManualMultiSelect || selection.count > 1
  }

  /// Hovering must not retarget the row while the preview is open.
  ///
  /// The preview is opened deliberately for one item, and the pointer has to
  /// travel across the list to reach it. Auto-open is off in this fork, so an
  /// open preview means the user asked for it: treat it as a focused mode.
  ///
  /// This lives here, next to the state it guards, rather than in the view that
  /// records the hover. It was only in the view before, which is exactly how the
  /// bug survived two attempts at it: suppressing the *write* left
  /// `hoverSelectionWhileKeyboardNavigating` holding a row from before the
  /// preview opened, and the next mouse movement -- the movement that carries the
  /// pointer over to click into the editor -- still applied it.
  var hoverSelectionSuppressed: Bool {
    ForkStyle.isActive
      && (AppState.shared.preview.state.isOpen || AppState.shared.preview.state.isAnimating)
  }

  /// The row the pointer is currently over, remembered while the keyboard is
  /// driving so that going back to the mouse picks up where the pointer sits.
  ///
  /// `onHover` only fires when the pointer crosses a row boundary, so this cannot
  /// be recomputed on demand -- it has to be remembered. That makes it a landmine
  /// if it is ever left holding a row the user has since moved off, or a row from
  /// a previous time the popup was open, which is why `forgetHoverSelection()`
  /// exists and is called whenever the list stops being what it was.
  var hoverSelectionWhileKeyboardNavigating: UUID?

  /// Drop the remembered hover. Cheap, and the safe thing to do any time the
  /// pointer's row is no longer known to be current.
  func forgetHoverSelection() {
    hoverSelectionWhileKeyboardNavigating = nil
  }

  var isKeyboardNavigating: Bool = true {
    didSet {
      guard !isKeyboardNavigating, !isMultiSelectInProgress,
            let hoverSelection = hoverSelectionWhileKeyboardNavigating else { return }

      // Consumed either way: whatever happens next, this is no longer a fresh
      // reading of where the pointer is.
      hoverSelectionWhileKeyboardNavigating = nil
      guard !hoverSelectionSuppressed else { return }

      select(id: hoverSelection)
    }
  }

  var isFirstItemHighlighted: Bool { history.firstVisibleItem == leadHistoryItem }

  private func scroll(to id: UUID?, item: HistoryItemDecorator? = nil) {
    scrollTarget = id
  }

  /// Select whatever the id names. An id that names nothing is ignored rather
  /// than treated as "select nothing": its only caller is the remembered hover,
  /// which can outlive the row it points at, and clearing the selection there
  /// leaves the popup with no lead item -- which in turn makes Up, Down and Return
  /// all no-ops with nothing on screen to say why.
  func select(id: UUID) {
    if let item = history.items.first(where: { $0.id == id }) {
      select(item: item, footerItem: nil)
    } else if let item = footer.items.first(where: { $0.id == id }) {
      select(item: nil, footerItem: item)
    }
  }

  func select(item: HistoryItemDecorator? = nil, footerItem: FooterItem? = nil) {
    withTransaction(Transaction()) {
      selectWithoutScrolling(item: item, footerItem: footerItem)
      scroll(to: item?.id, item: item)
    }
  }

  func addToSelection(item: HistoryItemDecorator) {
    var newSelectionState = selection

    if item.isSelected {
      if newSelectionState.count <= 1 {
        isManualMultiSelect = !isManualMultiSelect
      } else {
        newSelectionState.remove(item)
      }
    } else {
      newSelectionState.add(item)
    }

    withTransaction(Transaction()) {
      selection = newSelectionState
      leadHistoryItem = item
      scrollTarget = leadSelection
    }
  }

  func extendSelection(
    from fromItem: HistoryItemDecorator,
    to toItem: HistoryItemDecorator,
    isRange: Bool
  ) {
    var newSelectionState = selection

    if isRange {
      if let itemRange = history.visibleItems.between(
        from: fromItem,
        to: toItem,
        inOrder: false
      ) {
        newSelectionState = Selection(items: itemRange)
      }
    } else {
      if toItem.isSelected {
        newSelectionState.remove(fromItem)
      } else {
        newSelectionState.add(toItem)
      }
    }

    withTransaction(Transaction()) {
      selection = newSelectionState
      leadHistoryItem = toItem
      scrollTarget = leadSelection
    }
  }

  func selectWithoutScrolling(id: UUID) {
    if let stack = history.pasteStack,
       stack.id == id {
      selectWithoutScrolling(item: nil, footerItem: nil)
    } else if let item = history.items.first(where: { $0.id == id }) {
      if !isMultiSelectInProgress {
        selectWithoutScrolling(item: item, footerItem: nil)
      }
    } else if let item = footer.items.first(where: { $0.id == id }) {
      selectWithoutScrolling(item: nil, footerItem: item)
    } else {
      selectWithoutScrolling(item: nil, footerItem: nil)
    }
  }

  func selectWithoutScrolling(
    item: HistoryItemDecorator? = nil,
    footerItem: FooterItem? = nil
  ) {
    if let item = item {
      selectInHistory(item)
    } else if let footerItem = footerItem {
      selectInFooter(footerItem)
    } else {
      leadHistoryItem = nil
      selection = .init()
      footer.selectedItem = nil
    }
  }

  private func selectInHistory(_ item: HistoryItemDecorator) {
    leadHistoryItem = item
    selection = .init(items: [item])
    footer.selectedItem = nil
  }

  private func selectInFooter(_ item: FooterItem) {
    leadHistoryItem = nil
    if !isMultiSelectInProgress {
      selection = .init()
    }
    footer.selectedItem = item
  }

  private func selectFromKeyboardNavigation(
    item: HistoryItemDecorator? = nil,
    footerItem: FooterItem? = nil
  ) {
    isKeyboardNavigating = true
    isManualMultiSelect = false
    select(item: item, footerItem: footerItem)
  }

  private func extendHistorySelectionFromKeyboardNavigation(
    from fromItem: HistoryItemDecorator,
    to toItem: HistoryItemDecorator,
    isRange: Bool
  ) {
    isKeyboardNavigating = true
    extendSelection(from: fromItem, to: toItem, isRange: isRange)
  }

  func highlightFirst() {
    if let item = history.firstVisibleItem {
      selectFromKeyboardNavigation(item: item)
    } else {
      selectFromKeyboardNavigation(item: nil)
    }
  }

  func highlightPrevious() {
    guard let lead = leadSelection else {
      // Search is the visual row above history in the fork. Up from there wraps
      // directly to the last result, just as Down enters at the first result.
      if ForkStyle.isActive, let last = history.lastVisibleItem {
        selectFromKeyboardNavigation(item: last)
      }
      return
    }

    if leadSelection == history.pasteStack?.id {
      if ForkStyle.isActive, let last = history.lastVisibleItem {
        selectFromKeyboardNavigation(item: last)
      }
      return
    }

    if let historyItem = history.firstVisibleItem(where: { $0.id == lead }) {
      if let nextItem = history.visibleItem(before: historyItem) {
        selectFromKeyboardNavigation(item: nextItem)
      } else if history.pasteStack != nil {
        selectWithoutScrolling(item: nil)
      } else if ForkStyle.isActive, let last = history.lastVisibleItem {
        // Up from the top wraps to the end of what is loaded, rather than
        // stalling on the first row.
        selectFromKeyboardNavigation(item: last)
      } else {
        highlightFirst()
      }
    } else if let footerItem = footer.firstVisibleItem(where: { $0.id == lead }) {
      if let nextItem = footer.visibleItem(before: footerItem) {
        selectFromKeyboardNavigation(footerItem: nextItem)
      } else if let nextItem = history.lastVisibleItem {
        selectFromKeyboardNavigation(item: nextItem)
      }
    }
  }

  func highlightNext(allowCycle: Bool = false) {
    guard let lead = leadSelection else {
      if ForkStyle.isActive {
        highlightFirst()
      }
      return
    }

    if leadSelection == history.pasteStack?.id {
      highlightFirst()
      return
    }

    if let historyItem = history.firstVisibleItem(where: { $0.id == lead }) {
      if let nextItem = history.visibleItem(after: historyItem) {
        selectFromKeyboardNavigation(item: nextItem)
      } else if ForkStyle.isActive {
        // Tahoe presents history as a self-contained result list; footer actions
        // are reached elsewhere. Match Up's edge behavior by wrapping Down from
        // the last result to the visual first result (the paste stack, if any).
        if history.pasteStack != nil {
          selectFromKeyboardNavigation(item: nil)
        } else {
          highlightFirst()
        }
      } else if let nextItem = footer.firstVisibleItem {
        selectFromKeyboardNavigation(footerItem: nextItem)
      } else if allowCycle {
        highlightFirst()
      }
    } else if let footerItem = footer.firstVisibleItem(where: { $0.id == lead }) {
      if let nextItem = footer.visibleItem(after: footerItem) {
        selectFromKeyboardNavigation(footerItem: nextItem)
      } else if let nextItem = footer.firstVisibleItem {
        selectFromKeyboardNavigation(footerItem: nextItem)
      } else if allowCycle {
        // End of footer; cycle to the beginning
        highlightFirst()
      }
    }
  }

  func highlightLast() {
    guard let lead = leadSelection else {
      if ForkStyle.isActive, let last = history.lastVisibleItem {
        selectFromKeyboardNavigation(item: last)
      }
      return
    }

    if let historyItem = history.firstVisibleItem(where: { $0.id == lead }) {
      if !ForkStyle.isActive, historyItem == history.lastVisibleItem,
         let nextItem = footer.firstVisibleItem {
        selectFromKeyboardNavigation(footerItem: nextItem)
      } else {
        selectFromKeyboardNavigation(item: history.lastVisibleItem)
      }
    } else if footer.selectedItem != nil {
      selectFromKeyboardNavigation(footerItem: footer.lastVisibleItem)
    } else {
      selectFromKeyboardNavigation(footerItem: footer.firstVisibleItem)
    }
  }

  func extendHighlightToNext() {
    if let leadSelection,
       let leadItem = history.firstVisibleItem(where: {$0.id == leadSelection}) {
      guard let nextItem = history.visibleItem(after: leadItem) else { return }
      extendHistorySelectionFromKeyboardNavigation(from: leadItem, to: nextItem, isRange: false)
    } else {
      highlightNext()
    }
  }

  func extendHighlightToPrevious() {
    if let leadSelection,
       let leadItem = history.firstVisibleItem(where: {$0.id == leadSelection}) {
      guard let nextItem = history.visibleItem(before: leadItem) else { return }
      extendHistorySelectionFromKeyboardNavigation(from: leadItem, to: nextItem, isRange: false)
    } else {
      highlightPrevious()
    }
  }

  func extendHighlightToFirst() {
    if let leadSelection,
       let leadItem = history.firstVisibleItem(where: {$0.id == leadSelection}) {
      guard let nextItem = history.firstVisibleItem else { return }
      extendHistorySelectionFromKeyboardNavigation(from: leadItem, to: nextItem, isRange: true)
    } else {
      highlightFirst()
    }
  }

  func extendHighlightToLast() {
    if let leadSelection,
       let leadItem = history.firstVisibleItem(where: {$0.id == leadSelection}) {
      guard let nextItem = history.lastVisibleItem else { return }
      extendHistorySelectionFromKeyboardNavigation(from: leadItem, to: nextItem, isRange: true)
    } else {
      highlightFirst()
    }
  }

}
