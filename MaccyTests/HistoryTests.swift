import XCTest
import Defaults
import SwiftData
@testable import Maccy

@MainActor
class HistoryTests: XCTestCase { // swiftlint:disable:this type_body_length
  let savedSize = Defaults[.size]
  let savedSortBy = Defaults[.sortBy]
  let savedPinTo = Defaults[.pinTo]
  let history = History.shared

  override func setUp() {
    super.setUp()
    AppState.shared.focusSearchRow()
    history.clearAll()
    Defaults[.size] = 10
    Defaults[.sortBy] = .firstCopiedAt
    Defaults[.pinTo] = .bottom
  }

  override func tearDown() {
    super.tearDown()
    Defaults[.size] = savedSize
    Defaults[.sortBy] = savedSortBy
    Defaults[.pinTo] = savedPinTo
  }

  func testDefaultIsEmpty() {
    XCTAssertEqual(history.items, [])
  }

  func testAdding() {
    let first = history.add(historyItem("foo"))
    let second = history.add(historyItem("bar"))
    XCTAssertEqual(history.items, [second, first])
  }

  func testAddingPersistedDuplicate() throws {
    let first = historyItem("foo")
    first.title = "xyz"
    first.application = "iTerm.app"
    history.add(first)
    first.pin = "f"

    let third = historyItem("foo")
    third.application = "Xcode.app"
    let transferredContents = first.contents
    let merged = history.add(third)

    XCTAssertEqual(history.all, [merged])
    XCTAssertEqual(Set(merged.item.contents), Set(transferredContents))
    XCTAssertTrue(merged.item.lastCopiedAt > merged.item.firstCopiedAt)
    XCTAssertEqual(merged.item.numberOfCopies, 2)
    XCTAssertEqual(merged.item.pin, "f")
    XCTAssertEqual(merged.item.title, "xyz")
    XCTAssertEqual(merged.item.application, "iTerm.app")
    try assertStorageCounts(items: 1, contents: 1)
  }

  func testAddingUnsavedDuplicate() throws {
    guard #available(macOS 15.0, *) else {
      throw XCTSkip("Incoming history items are inserted before add on macOS 14")
    }

    let first = historyItem("foo")
    first.title = "xyz"
    first.application = "iTerm.app"
    history.add(first)
    first.pin = "f"

    let second = historyItem("foo", persisted: false)
    second.application = "Xcode.app"
    let transferredContents = first.contents
    let merged = history.add(second)

    XCTAssertEqual(history.all, [merged])
    XCTAssertEqual(Set(merged.item.contents), Set(transferredContents))
    XCTAssertTrue(merged.item.lastCopiedAt > merged.item.firstCopiedAt)
    XCTAssertEqual(merged.item.numberOfCopies, 2)
    XCTAssertEqual(merged.item.pin, "f")
    XCTAssertEqual(merged.item.title, "xyz")
    XCTAssertEqual(merged.item.application, "iTerm.app")
    try assertStorageCounts(items: 1, contents: 1)
  }

  func testAddingItemThatIsSupersededByExisting() throws {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.rtf.rawValue,
        value: "two".data(using: .utf8)!
      )
    ]
    let firstItem = HistoryItem()
    Storage.shared.context.insert(firstItem)
    firstItem.application = "Maccy.app"
    firstItem.contents = firstContents
    firstItem.title = firstItem.generateTitle()
    history.add(firstItem)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      )
    ]
    let secondItem = HistoryItem()
    Storage.shared.context.insert(secondItem)
    secondItem.application = "Maccy.app"
    secondItem.contents = secondContents
    secondItem.title = secondItem.generateTitle()
    let second = history.add(secondItem)

    XCTAssertEqual(history.items, [second])
    XCTAssertEqual(Set(history.items[0].item.contents), Set(firstContents))
    try assertStorageCounts(items: 1, contents: firstContents.count)
  }

  func testAddingItemWithDifferentModifiedType() {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: "1".data(using: .utf8)!
      )
    ]
    let firstItem = HistoryItem()
    Storage.shared.context.insert(firstItem)
    firstItem.contents = firstContents
    history.add(firstItem)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)!
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.modified.rawValue,
        value: "2".data(using: .utf8)!
      )
    ]
    let secondItem = HistoryItem()
    Storage.shared.context.insert(secondItem)
    secondItem.contents = secondContents
    let second = history.add(secondItem)

    XCTAssertEqual(history.items, [second])
    XCTAssertEqual(Set(history.items[0].item.contents), Set(firstContents))
  }

  func testAddingItemFromMaccy() {
    let firstContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)
      )
    ]
    let first = HistoryItem()
    Storage.shared.context.insert(first)
    first.application = "Xcode.app"
    first.contents = firstContents
    history.add(first)

    let secondContents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: "one".data(using: .utf8)
      ),
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.fromMaccy.rawValue,
        value: "".data(using: .utf8)
      )
    ]
    let second = HistoryItem()
    Storage.shared.context.insert(second)
    second.application = "Maccy.app"
    second.contents = secondContents
    let secondDecorator = history.add(second)

    XCTAssertEqual(history.items, [secondDecorator])
    XCTAssertEqual(history.items[0].item.application, "Xcode.app")
    XCTAssertEqual(Set(history.items[0].item.contents), Set(firstContents))
  }

  func testModifiedAfterCopying() {
    history.add(historyItem("foo"))

    let modifiedItem = historyItem("bar")
    modifiedItem.contents.append(HistoryItemContent(
      type: NSPasteboard.PasteboardType.modified.rawValue,
      value: String(Clipboard.shared.changeCount).data(using: .utf8)
    ))
    let modifiedItemDecorator = history.add(modifiedItem)

    XCTAssertEqual(history.items, [modifiedItemDecorator])
    XCTAssertEqual(history.items[0].text, "bar")
  }

  func testClearingUnpinned() throws {
    let pinned = history.add(historyItem("foo"))
    pinned.togglePin()
    history.add(historyItem("bar"))
    let orphan = HistoryItemContent(
      type: NSPasteboard.PasteboardType.string.rawValue,
      value: "orphan".data(using: .utf8)
    )
    Storage.shared.context.insert(orphan)
    try Storage.shared.context.save()

    history.clear()

    XCTAssertEqual(history.items, [pinned])
    try assertStorageCounts(items: 1, contents: 1)
  }

  func testClearingAll() throws {
    history.add(historyItem("foo"))
    let pinned = history.add(historyItem("bar"))
    pinned.togglePin()
    Storage.shared.context.insert(HistoryItemContent(
      type: NSPasteboard.PasteboardType.string.rawValue,
      value: "orphan".data(using: .utf8)
    ))
    try Storage.shared.context.save()

    history.clearAll()

    XCTAssertEqual(history.items, [])
    try assertStorageCounts(items: 0, contents: 0)
  }

  func testMaxSize() throws {
    var items: [HistoryItemDecorator] = []
    for index in 0...10 {
      items.append(history.add(historyItem(String(index))))
    }

    XCTAssertEqual(history.items.count, 10)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertFalse(history.items.contains(items[0]))
    try assertStorageCounts(items: 10, contents: 10)
  }

  func testMaxSizeIgnoresPinned() {
    var items: [HistoryItemDecorator] = []

    let item = history.add(historyItem("0"))
    items.append(item)
    item.togglePin()

    for index in 1...11 {
      items.append(history.add(historyItem(String(index))))
    }

    XCTAssertEqual(history.items.count, 11)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertTrue(history.items.contains(items[0]))
    XCTAssertFalse(history.items.contains(items[1]))
  }

  func testMaxSizeIsChanged() {
    var items: [HistoryItemDecorator] = []
    for index in 0...10 {
      items.append(history.add(historyItem(String(index))))
    }
    Defaults[.size] = 5
    history.add(historyItem("11"))

    XCTAssertEqual(history.items.count, 5)
    XCTAssertTrue(history.items.contains(items[10]))
    XCTAssertFalse(history.items.contains(items[5]))
  }

  func testReassigningSameSearchQueryKeepsSelection() async throws {
    // Normalize any query left by another test and let its real refresh finish.
    history.searchQuery = ""
    try await Task.sleep(for: .milliseconds(250))

    let older = history.add(historyItem("older"))
    history.add(historyItem("newer"))
    AppState.shared.navigator.select(item: older)

    // SwiftUI writes this unchanged value when focus leaves the search field for
    // the AppKit preview editor. It must not be mistaken for a new search.
    history.searchQuery = history.searchQuery
    try await Task.sleep(for: .milliseconds(250))

    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem, older)
  }

  func testPreviewKeepsEveryArrowAndModifierInEditor() throws {
    guard ForkStyle.isActive else {
      throw XCTSkip("Editable preview is enabled by the macOS 26 fork")
    }

    let arrowKeyCodes: [UInt16] = [123, 124, 125, 126]
    let modifierVariants: [NSEvent.ModifierFlags] = [
      [], [.shift], [.command], [.control], [.option], [.command, .shift]
    ]

    for keyCode in arrowKeyCodes {
      for modifiers in modifierVariants {
        XCTAssertFalse(PreviewTextView.shouldRouteToPopup(
          keyCode: keyCode,
          modifierFlags: modifiers
        ))
      }
    }

    for keyCode: UInt16 in [36, 48, 53, 76] {
      XCTAssertTrue(PreviewTextView.shouldRouteToPopup(
        keyCode: keyCode,
        modifierFlags: []
      ))
    }
  }

  func testScopePickerRightArrowDismissesPicker() throws {
    guard ForkStyle.isActive else {
      throw XCTSkip("Scope picker is enabled by the macOS 26 fork")
    }

    AppState.shared.scopePickerOpen = true
    defer { AppState.shared.resetScopePicker() }

    guard case .closeScopePicker = KeyChord(.rightArrow, []) else {
      return XCTFail("Expected Right arrow to dismiss the open scope picker")
    }
  }

  func testScopePickerAlignmentHeightTracksVisibleRows() throws {
    guard ForkStyle.isActive else {
      throw XCTSkip("Scope picker is enabled by the macOS 26 fork")
    }

    XCTAssertEqual(
      ScopePickerView.contentHeight(for: ScopePickerRow.ordered),
      183
    )
    XCTAssertEqual(
      ScopePickerView.contentHeight(for: [.settings]),
      38
    )
  }

  func testFirstPreviewEscapeOnlyLeavesEditorFocus() throws {
    guard ForkStyle.isActive else {
      throw XCTSkip("Editable preview is enabled by the macOS 26 fork")
    }

    let previousState = AppState.shared.preview.state
    let item = history.add(historyItem("escape preview draft"))
    PreviewEditor.shared.begin(item: item)
    PreviewEditor.shared.isFocused = true
    AppState.shared.preview.state = .open
    defer {
      PreviewEditor.shared.begin(item: nil)
      AppState.shared.preview.state = previousState
    }

    XCTAssertTrue(AppState.shared.handlePreviewEscape())
    XCTAssertFalse(PreviewEditor.shared.isFocused)
    XCTAssertTrue(AppState.shared.preview.state.isOpen)
  }

  func testPagedHistoryRemainsCompleteScrollableAndSearchable() async throws {
    guard ForkStyle.isActive else {
      throw XCTSkip("Paged history is enabled by the macOS 26 fork")
    }

    // Cross both paging boundaries (60-row first paint and 120-row remainder)
    // so this exercises the same storage path as a real, scrollable history.
    Defaults[.size] = 250
    let total = 181
    for index in 0..<total {
      let title = index == 0 ? "unique-deep-history-entry" : "paged-history-\(index)"
      let item = historyItem(title)
      let timestamp = Date(timeIntervalSince1970: TimeInterval(index + 1))
      item.firstCopiedAt = timestamp
      item.lastCopiedAt = timestamp
    }
    Storage.shared.context.processPendingChanges()
    try Storage.shared.context.save()

    // Model a relaunch: nothing is kept in the in-memory arrays, but the SwiftData
    // store is intact. load() must rebuild every page without dropping the tail.
    history.all = []
    history.items = []
    try await history.load()
    await waitUntil { self.history.all.count == total }

    XCTAssertEqual(history.all.count, total)
    XCTAssertEqual(history.items.count, total)
    XCTAssertEqual(history.all.first?.title, "paged-history-180")
    XCTAssertEqual(history.all.last?.title, "unique-deep-history-entry")
    try assertStorageCounts(items: total, contents: total)

    guard let last = history.lastVisibleItem else {
      return XCTFail("Expected the oldest loaded history row")
    }
    AppState.shared.navigator.select(item: last)
    XCTAssertEqual(AppState.shared.navigator.scrollTarget, last.id)

    history.searchQuery = "unique-deep-history-entry"
    await waitUntil {
      self.history.items.count == 1
        && self.history.items.first?.title == "unique-deep-history-entry"
    }
    XCTAssertEqual(history.items.first?.item, last.item)

    history.searchQuery = ""
    await waitUntil { self.history.items.count == total }
  }

  func testForkHistoryNavigationWrapsAtBothEnds() throws {
    guard ForkStyle.isActive else {
      throw XCTSkip("Cyclic history navigation is enabled by the macOS 26 fork")
    }

    history.add(historyItem("oldest"))
    history.add(historyItem("middle"))
    history.add(historyItem("newest"))

    guard let first = history.firstVisibleItem,
          let last = history.lastVisibleItem else {
      return XCTFail("Expected populated history")
    }

    AppState.shared.navigator.select(item: first)
    AppState.shared.navigator.highlightPrevious()
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem, last)

    AppState.shared.navigator.highlightNext()
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem, first)
  }

  func testPlainTextActionOnlyOpensFromHistoryKeyboardContext() throws {
    guard ForkStyle.isActive else {
      throw XCTSkip("Contextual Left-arrow actions are enabled by the macOS 26 fork")
    }

    let item = history.add(historyItem("plain text action"))
    AppState.shared.navigator.select(item: item)

    AppState.shared.focusSearchRow()
    XCTAssertNil(AppState.shared.navigator.leadHistoryItem)
    AppState.shared.openPlainTextAction()
    XCTAssertNil(AppState.shared.plainTextActionItemID)

    AppState.shared.focusHistoryRow()
    AppState.shared.navigator.highlightNext()
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem, item)
    AppState.shared.openPlainTextAction()
    XCTAssertEqual(AppState.shared.plainTextActionItemID, item.id)
    XCTAssertTrue(AppState.shared.dismissPlainTextAction())
    XCTAssertNil(AppState.shared.plainTextActionItemID)
  }

  func testForkSearchRowEntersHistoryAtVisibleEdges() throws {
    guard ForkStyle.isActive else {
      throw XCTSkip("Search-row navigation is enabled by the macOS 26 fork")
    }

    history.add(historyItem("oldest"))
    history.add(historyItem("middle"))
    history.add(historyItem("newest"))
    let first = try XCTUnwrap(history.firstVisibleItem)
    let last = try XCTUnwrap(history.lastVisibleItem)

    AppState.shared.focusSearchRow()
    XCTAssertNil(AppState.shared.navigator.leadHistoryItem)

    AppState.shared.focusHistoryRow()
    AppState.shared.navigator.highlightNext()
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem, first)

    AppState.shared.focusSearchRow()
    AppState.shared.focusHistoryRow()
    AppState.shared.navigator.highlightPrevious()
    XCTAssertEqual(AppState.shared.navigator.leadHistoryItem, last)
  }

  func testReaddingBottomMostPinnedItemAtFullCapacity() {
    // Regression test for a crash when re-copying (invoking) the bottom-most
    // pinned item while history is at full capacity and pins are sorted to the
    // bottom. The stale insert index used to trap with an out-of-bounds insert.
    // Issue link: https://github.com/p0deje/Maccy/issues/1466
    // `pinTo` is restored to its default value(.top) in `tearDown`.
    Defaults[.pinTo] = .bottom

    // Pin an item; `history.togglePin` re-sorts `all`, so with `.bottom` the
    // pinned item ends up as the last element.
    let pinned = history.add(historyItem("pinned"))
    history.togglePin(pinned)

    // Fill unpinned history to full capacity.
    for index in 0..<Defaults[.size] {
      history.add(historyItem(String(index)))
    }

    XCTAssertEqual(history.all.last, pinned)

    // Re-copy the pinned item. It is detected as a duplicate, removed and
    // re-inserted while `limitHistorySize` trims an exceeding unpinned item.
    // Before the fix this inserted at a stale, out-of-bounds index and crashed.
    let readded = history.add(historyItem("pinned"))

    XCTAssertTrue(history.all.contains(readded))
    XCTAssertEqual(history.all.filter(\.isPinned).count, 1)
  }

  func testRemoving() throws {
    let foo = history.add(historyItem("foo"))
    let bar = history.add(historyItem("bar"))
    history.delete(foo)
    XCTAssertEqual(history.items, [bar])
    try assertStorageCounts(items: 1, contents: 1)
  }

  func testCleaningUpOrphanedContents() throws {
    let live = history.add(historyItem("live"))
    let liveContent = live.item.contents[0]
    for value in ["orphan-1", "orphan-2"] {
      Storage.shared.context.insert(HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.data(using: .utf8)
      ))
    }
    try Storage.shared.context.save()

    XCTAssertEqual(try Storage.shared.cleanupOrphanedContents(), 2)
    XCTAssertEqual(try Storage.shared.cleanupOrphanedContents(), 0)
    XCTAssertEqual(live.item.contents, [liveContent])
    try assertStorageCounts(items: 1, contents: 1)
  }

  private func assertStorageCounts(
    items: Int,
    contents: Int,
    orphaned: Int = 0,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let context = Storage.shared.context
    context.processPendingChanges()
    try context.save()
    XCTAssertEqual(
      try context.fetchCount(FetchDescriptor<HistoryItem>()),
      items,
      file: file,
      line: line
    )
    XCTAssertEqual(
      try context.fetchCount(FetchDescriptor<HistoryItemContent>()),
      contents,
      file: file,
      line: line
    )
    XCTAssertEqual(
      try context.fetchCount(FetchDescriptor<HistoryItemContent>(
        predicate: #Predicate { $0.item == nil }
      )),
      orphaned,
      file: file,
      line: line
    )
  }

  private func waitUntil(
    _ condition: @escaping @MainActor () -> Bool,
    attempts: Int = 250
  ) async {
    for _ in 0..<attempts {
      if condition() { return }
      try? await Task.sleep(for: .milliseconds(20))
    }
    XCTFail("Timed out waiting for asynchronous history update")
  }

  private func historyItem(_ value: String, persisted: Bool = true) -> HistoryItem {
    let contents = [
      HistoryItemContent(
        type: NSPasteboard.PasteboardType.string.rawValue,
        value: value.data(using: .utf8)
      )
    ]
    let item = HistoryItem()
    if persisted {
      Storage.shared.context.insert(item)
    }
    item.contents = contents
    item.numberOfCopies = 1
    item.title = item.generateTitle()

    return item
  }
}
