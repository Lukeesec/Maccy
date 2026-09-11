// swiftlint:disable file_length
import AppKit.NSRunningApplication
import Defaults
import Foundation
import Logging
import Observation
import Sauce
import Settings
import SwiftData

@Observable
class History: ItemsContainer { // swiftlint:disable:this type_body_length
  static let shared = History()
  let logger = Logger(label: "org.p0deje.Maccy")

  var items: [HistoryItemDecorator] = []
  var pasteStack: PasteStack?

  var pinnedItems: [HistoryItemDecorator] { items.filter(\.isPinned) }
  var unpinnedItems: [HistoryItemDecorator] { items.filter(\.isUnpinned) }

  var searchQuery: String = "" {
    didSet {
      // SwiftUI can write the field's current value back through its binding when
      // focus moves to the AppKit preview editor. Treat that as a focus event, not
      // a new search: refreshing with resetSelection would otherwise jump to the
      // first result just as the editor takes focus.
      guard oldValue != searchQuery else { return }

      throttler.throttle { [self] in
        Task { @MainActor in
          refreshItems(resetSelection: true)
        }
      }
    }
  }

  /// Spotlight-style scope filter. Inert unless `ForkStyle.isActive`, so macOS 14
  /// and 15 keep upstream's unfiltered list.
  ///
  /// Changing it goes through exactly the same refresh path as changing
  /// `searchQuery`: the scope narrows the candidate set, the search then runs
  /// over what is left.
  var scope: ForkScope = .all {
    didSet {
      guard oldValue != scope else { return }

      Task { @MainActor in
        refreshItems(resetSelection: true)
      }
    }
  }

  var pressedShortcutItem: HistoryItemDecorator? {
    guard let event = NSApp.currentEvent else {
      return nil
    }

    let modifierFlags = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting(.capsLock)

    guard HistoryItemAction(modifierFlags) != .unknown else {
      return nil
    }

    let key = Sauce.shared.key(for: Int(event.keyCode))
    return items.first { $0.shortcuts.contains(where: { $0.key == key }) }
  }

  // Enough rows to fill the popup at its tallest, so the first paint is complete.
  // The rest arrives page by page, yielding to the main actor between pages.
  private static let firstPageSize = 60
  private static let pageSize = 120

  // Recomputing `items` costs a `Search` pass over everything loaded so far, and
  // a SQLite query on top of that when a query is live. Doing it once per page
  // is what made paging quadratic, so it is coalesced: at most one refresh per
  // interval while paging runs, plus one guaranteed refresh when it finishes.
  private static let refreshInterval: TimeInterval = 0.15

  private let search = Search()
  private let sorter = Sorter()
  private let throttler = Throttler(minimumDelay: 0.2)

  @ObservationIgnored
  private var sessionLog: [Int: HistoryItem] = [:]

  @ObservationIgnored
  private var loadTask: Task<Void, Never>?

  // The distinction between `all` and `items` is the following:
  // - `all` stores all history items, even the ones that are currently hidden by a search
  // - `items` stores only visible history items, updated during a search
  @ObservationIgnored
  var all: [HistoryItemDecorator] = []

  init() {
    Task {
      for await _ in Defaults.updates(.pasteByDefault, initial: false) {
        updateShortcuts()
      }
    }

    Task {
      for await _ in Defaults.updates(.sortBy, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.pinTo, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.showSpecialSymbols, initial: false) {
        for item in items {
          await updateTitle(item: item, title: item.item.generateTitle())
        }
      }
    }

    Task {
      for await _ in Defaults.updates(.imageMaxHeight, initial: false) {
        for item in items {
          await item.cleanupImages()
        }
      }
    }
  }

  @MainActor
  func load() async throws {
    loadTask?.cancel()
    loadTask = nil

    guard ForkStyle.isActive else {
      let descriptor = FetchDescriptor<HistoryItem>()
      let results = try Storage.shared.context.fetch(descriptor)
      all = sorter.sort(results).map { HistoryItemDecorator($0) }
      items = all

      limitHistorySize(to: Defaults[.size])

      updateShortcuts()
      // Ensure that panel size is proper *after* loading all items.
      Task {
        AppState.shared.popup.needsResize = true
      }
      return
    }

    // Pinned items are few - the pin alphabet is a fixed 21 characters - and
    // `Sorter` has to place them relative to everything else, so they are always
    // fetched in full. Only unpinned items are paged.
    let sortBy = Defaults[.sortBy]
    let pinned = (try? Storage.shared.fetchPinnedHistoryItems()) ?? []
    let firstPage = (try? Storage.shared.fetchUnpinnedHistoryItems(
      after: nil,
      limit: Self.firstPageSize,
      sortBy: sortBy
    )) ?? []

    all = sorter.sort(pinned + firstPage, by: sortBy).map { HistoryItemDecorator($0) }
    refreshItems(resetSelection: false)
    updateShortcuts()
    AppState.shared.popup.needsResize = true

    guard firstPage.count == Self.firstPageSize, let boundary = firstPage.last else {
      // The whole history fits in one page, so there is nothing to continue.
      limitHistorySize(to: Defaults[.size])
      updateShortcuts()
      return
    }

    let cursor = HistoryPageCursor(boundary)
    loadTask = Task { @MainActor [weak self] in
      await self?.loadRemainder(after: cursor, by: sortBy)
    }
  }

  /// Page in everything after the first page, yielding between pages so the
  /// popup stays responsive while it happens.
  ///
  /// Paging is keyset-based: each page resumes from the previous page's last
  /// row *by value*. It cannot use `fetchOffset`, because this very class writes
  /// to the store while the paging runs — `add()` deletes the row it
  /// consolidates a duplicate into, `delete()` removes whatever the user picked,
  /// `limitHistorySize` trims the tail — and every delete below the current
  /// offset would shift the store up by one and step the reader over exactly one
  /// row for the rest of the session. See `HistoryPageCursor`.
  @MainActor
  private func loadRemainder(after start: HistoryPageCursor, by sortBy: Sorter.By) async {
    var cursor = start
    var limit = Self.pageSize
    var pendingRefresh = false
    var lastRefresh = Date.now

    while !Task.isCancelled {
      await Task.yield()
      guard !Task.isCancelled else { return }

      guard let page = try? Storage.shared.fetchUnpinnedHistoryItems(
        after: cursor,
        limit: limit,
        sortBy: sortBy
      ), let boundary = page.last else {
        break
      }

      let added = merge(page, by: sortBy)
      pendingRefresh = pendingRefresh || added > 0

      let read = page.count
      cursor = HistoryPageCursor(boundary)

      if read < limit {
        break
      }

      if added == 0 {
        // A whole page of rows already loaded. The cursor's bound is inclusive
        // on the tiebreaker, so this can only happen when more than `limit` rows
        // share the cursor's key *and* its tiebreaker — pathological, but it
        // would otherwise re-read the same block forever. Widen the window until
        // it clears the block.
        limit *= 2
      } else {
        limit = Self.pageSize
      }

      if pendingRefresh, Date.now.timeIntervalSince(lastRefresh) >= Self.refreshInterval {
        refreshItems(resetSelection: false)
        AppState.shared.popup.needsResize = true
        pendingRefresh = false
        lastRefresh = Date.now
      }
    }

    guard !Task.isCancelled else { return }

    limitHistorySize(to: Defaults[.size])
    refreshItems(resetSelection: false)
    updateShortcuts()
    AppState.shared.popup.needsResize = true
    loadTask = nil
  }

  /// Fold a freshly paged batch into `all` in O(n + m), keeping `Sorter`'s
  /// ordering. Returns how many rows were genuinely new.
  ///
  /// `all` and `page` are each already in `Sorter`'s order, so their union is a
  /// linear merge rather than another sort. Re-sorting here meant one
  /// `Sorter.sort` — two chained full `sorted(by:)` passes — per page over a
  /// growing array, which for a 10k history is ~83 passes and asymptotically
  /// worse than the single fetch and single sort the paging replaced.
  ///
  /// Nothing here touches `items`: recomputing that runs a whole `Search` pass
  /// and is coalesced by the caller instead of fired once per page.
  ///
  /// The batch is still deduplicated against what is already loaded. That is for
  /// rows *added* mid-load, not deleted ones — a keyset cursor already survives
  /// deletes. A copy made while paging can still land below the cursor and be
  /// read a second time: a consolidated duplicate inherits the old item's
  /// `firstCopiedAt`, and its `numberOfCopies` is whatever the two summed to.
  @MainActor
  @discardableResult
  private func merge(_ page: [HistoryItem], by sortBy: Sorter.By) -> Int {
    let known = Set(all.map { ObjectIdentifier($0.item) })
    let incoming = page
      .filter { !known.contains(ObjectIdentifier($0)) }
      .map { HistoryItemDecorator($0) }
    guard !incoming.isEmpty else { return 0 }

    // `Sorter` sorts by key and then stably by pin, so `all` is a pinned block
    // and an unpinned block, each internally in key order. Only unpinned rows
    // are ever paged, so the merge happens entirely inside the unpinned block
    // and the pinned block is carried across untouched.
    var pinned: [HistoryItemDecorator] = []
    var unpinned: [HistoryItemDecorator] = []
    unpinned.reserveCapacity(all.count)
    for decorator in all {
      if decorator.isPinned {
        pinned.append(decorator)
      } else {
        unpinned.append(decorator)
      }
    }

    var merged: [HistoryItemDecorator] = []
    merged.reserveCapacity(unpinned.count + incoming.count)

    var left = 0
    var right = 0
    while left < unpinned.count, right < incoming.count {
      // Ties go to the already-loaded side, which is what `Sorter`'s stable sort
      // does for a single fetch: rows the store handed over earlier stay first.
      if Self.precedes(incoming[right].item, unpinned[left].item, by: sortBy) {
        merged.append(incoming[right])
        right += 1
      } else {
        merged.append(unpinned[left])
        left += 1
      }
    }
    merged.append(contentsOf: unpinned[left...])
    merged.append(contentsOf: incoming[right...])

    all = Defaults[.pinTo] == .bottom ? merged + pinned : pinned + merged

    return incoming.count
  }

  /// `Sorter`'s ordering predicate for a single key, minus the pin pass.
  ///
  /// Kept deliberately identical to `Sorter.bySortingAlgorithm`: `merge` has to
  /// produce exactly the order one fetch followed by one `Sorter.sort` would
  /// have produced, and the only way to guarantee that is to compare the same
  /// way.
  private static func precedes(_ lhs: HistoryItem, _ rhs: HistoryItem, by sortBy: Sorter.By) -> Bool {
    switch sortBy {
    case .firstCopiedAt:
      return lhs.firstCopiedAt > rhs.firstCopiedAt
    case .numberOfCopies:
      return lhs.numberOfCopies > rhs.numberOfCopies
    default:
      return lhs.lastCopiedAt > rhs.lastCopiedAt
    }
  }

  /// `all`, narrowed to the active scope. Identical to `all` on macOS 14 and 15,
  /// and whenever the scope is `.all`.
  @MainActor
  private func scopedItems() -> [HistoryItemDecorator] {
    guard ForkStyle.isActive, scope != .all else {
      return all
    }

    ForkItemKindCache.prune(expecting: all.count)
    return all.filter { scope.matches($0.item) }
  }

  /// The candidate set a search runs over: the scoped items, narrowed further by
  /// the store when the search mode allows it losslessly.
  @MainActor
  private func searchCandidates() -> [HistoryItemDecorator] {
    let scoped = scopedItems()

    guard ForkStyle.isActive,
          !searchQuery.isEmpty,
          Search.canNarrowInStore(Defaults[.searchMode]),
          let matched = try? Storage.shared.fetchHistoryItems(titleContaining: searchQuery) else {
      return scoped
    }

    let ids = Set(matched.map { ObjectIdentifier($0) })
    return scoped.filter { ids.contains(ObjectIdentifier($0.item)) }
  }

  /// The single place `items` is recomputed from `all`, the scope and the query.
  @MainActor
  private func refreshItems(resetSelection: Bool) {
    updateItems(search.search(string: searchQuery, within: searchCandidates()))

    guard resetSelection else { return }

    if searchQuery.isEmpty {
      AppState.shared.navigator.select(item: unpinnedItems.first)
    } else {
      AppState.shared.navigator.highlightFirst()
    }

    AppState.shared.popup.needsResize = true
  }

  @MainActor
  private func limitHistorySize(to maxSize: Int) {
    let unpinned = all.filter(\.isUnpinned)
    if unpinned.count >= maxSize {
      unpinned[maxSize...].forEach(delete)
    }
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    logger.info("Inserting item with id '\(item.title)'")
    Storage.shared.context.insert(item)
    Storage.shared.context.processPendingChanges()
    try? Storage.shared.context.save()
  }

  @discardableResult
  @MainActor
  func add(_ item: HistoryItem) -> HistoryItemDecorator {
    if #available(macOS 15.0, *) {
      try? History.shared.insertIntoStorage(item)
    } else {
      // On macOS 14 the history item needs to be inserted into storage directly after creating it.
      // It was already inserted after creation in Clipboard.swift
    }

    var removedItemIndex: Int?
    if let existingHistoryItem = findSimilarItem(item) {
      if isModified(item) == nil {
        transferContents(from: existingHistoryItem, to: item)
      }
      item.firstCopiedAt = existingHistoryItem.firstCopiedAt
      item.numberOfCopies += existingHistoryItem.numberOfCopies
      item.pin = existingHistoryItem.pin
      item.title = existingHistoryItem.title
      if !item.fromMaccy {
        item.application = existingHistoryItem.application
      }
      logger.info("Removing duplicate item '\(item.title)'")
      removedItemIndex = all.firstIndex(where: { $0.item == existingHistoryItem })
      if let removedItemIndex {
        cleanup(all[removedItemIndex])
      }
      deleteFromStorage(existingHistoryItem)
      if let removedItemIndex {
        all.remove(at: removedItemIndex)
      }
    } else {
      Task {
        Notifier.notify(body: item.title, sound: .write)
      }
    }

    // Remove exceeding items. Do this after the item is added to avoid removing something
    // if a duplicate was found as then the size already stayed the same.
    limitHistorySize(to: Defaults[.size] - 1)

    sessionLog[Clipboard.shared.changeCount] = item

    var itemDecorator: HistoryItemDecorator
    if let pin = item.pin {
      itemDecorator = HistoryItemDecorator(item, shortcuts: KeyShortcut.create(character: pin))
      if let removedItemIndex {
        // If pin to bottom -> last element should be inserted to the removedItemIndex - 1
        // Or to the last all array place.
        all.insert(itemDecorator, at: min(removedItemIndex, all.count))
      }
    } else {
      itemDecorator = HistoryItemDecorator(item)

      let sortedItems = sorter.sort(all.map(\.item) + [item])
      if let index = sortedItems.firstIndex(of: item) {
        all.insert(itemDecorator, at: index)
      }

      items = scopedItems()
      updateUnpinnedShortcuts()
      AppState.shared.popup.needsResize = true
    }

    return itemDecorator
  }

  @MainActor
  private func withLogging(_ msg: String, _ block: () throws -> Void) rethrows {
    func dataCounts() -> String {
      let historyItemCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItem>())
      let historyContentCount = try? Storage.shared.context.fetchCount(FetchDescriptor<HistoryItemContent>())
      return "HistoryItem=\(historyItemCount ?? 0) HistoryItemContent=\(historyContentCount ?? 0)"
    }

    logger.info("\(msg) Before: \(dataCounts())")
    try? block()
    logger.info("\(msg) After: \(dataCounts())")
  }

  @MainActor
  func clear() {
    withLogging("Clearing history") {
      all.forEach { item in
        if item.isUnpinned {
          cleanup(item)
        }
      }
      all.removeAll(where: \.isUnpinned)
      sessionLog.removeValues { $0.pin == nil }
      items = scopedItems()

      try? Storage.shared.context.transaction {
        try? Storage.shared.context.delete(
          model: HistoryItem.self,
          where: #Predicate { $0.pin == nil }
        )
        try? Storage.shared.context.delete(
          model: HistoryItemContent.self,
          where: #Predicate { $0.item?.pin == nil }
        )
      }
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func clearAll() {
    withLogging("Clearing all history") {
      all.forEach { item in
        cleanup(item)
      }
      all.removeAll()
      sessionLog.removeAll()
      items = scopedItems()

      do {
        let context = Storage.shared.context
        try context.transaction {
          // Bulk deletion cannot remove children with live inverse relationships.
          try context.delete(
            model: HistoryItemContent.self,
            where: #Predicate { $0.item == nil }
          )
          try context.delete(model: HistoryItem.self)
          try context.delete(model: HistoryItemContent.self)
        }
      } catch {
        logger.error("Failed to clear storage: \(String(reflecting: error))")
      }
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

    Clipboard.shared.clear()
    AppState.shared.popup.close()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  func delete(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    cleanup(item)
    withLogging("Removing history item") {
      deleteFromStorage(item.item)
      Storage.shared.context.processPendingChanges()
      try? Storage.shared.context.save()
    }

    all.removeAll { $0 == item }
    items.removeAll { $0 == item }
    sessionLog.removeValues { $0 == item.item }

    updateUnpinnedShortcuts()
    Task {
      AppState.shared.popup.needsResize = true
    }
  }

  @MainActor
  private func transferContents(from existingItem: HistoryItem, to newItem: HistoryItem) {
    deleteContents(of: newItem)
    newItem.contents = existingItem.contents
    existingItem.contents = []
  }

  @MainActor
  private func deleteFromStorage(_ item: HistoryItem) {
    deleteContents(of: item)
    Storage.shared.context.delete(item)
  }

  @MainActor
  private func deleteContents(of item: HistoryItem) {
    item.contents.forEach(Storage.shared.context.delete)
  }

  @MainActor
  private func cleanup(_ item: HistoryItemDecorator) {
    item.cleanupImages()
  }

  /// Put `item` on the clipboard, or - when the preview has been edited in place -
  /// the edited text instead.
  ///
  /// The scratch edit only ever changes what lands on the pasteboard. The stored
  /// `HistoryItem` is left exactly as it was; the edited text comes back around
  /// as a new clipboard entry like any other copy made from inside Maccy.
  @MainActor
  private func copyToPasteboard(_ item: HistoryItemDecorator, editedText: String?, removeFormatting: Bool) {
    if let editedText {
      Clipboard.shared.copyInMaccy(editedText)
    } else {
      Clipboard.shared.copy(item.item, removeFormatting: removeFormatting)
    }
  }

  @MainActor
  func select(_ item: HistoryItemDecorator?, flags modifierFlags: NSEvent.ModifierFlags) {
    if modifierFlags.isEmpty {
      performSelection(
        item,
        paste: Defaults[.pasteByDefault],
        removeFormatting: Defaults[.removeFormattingByDefault]
      )
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        performSelection(item, paste: false, removeFormatting: false)
      case .paste:
        performSelection(item, paste: true, removeFormatting: false)
      case .pasteWithoutFormatting:
        performSelection(item, paste: true, removeFormatting: true)
      case .unknown:
        return
      }
    }
  }

  /// An explicit paste used by the fork's primary Return action and its
  /// per-entry plain-text action. It deliberately bypasses the global defaults:
  /// the command itself completely describes what will happen.
  @MainActor
  func paste(_ item: HistoryItemDecorator?, removeFormatting: Bool) {
    performSelection(item, paste: true, removeFormatting: removeFormatting)
  }

  @MainActor
  func copy(_ item: HistoryItemDecorator?, removeFormatting: Bool) {
    performSelection(item, paste: false, removeFormatting: removeFormatting)
  }

  @MainActor
  private func performSelection(
    _ item: HistoryItemDecorator?,
    paste: Bool,
    removeFormatting: Bool
  ) {
    guard let item else { return }

    // Read the draft before anything closes the popup, so it cannot be discarded
    // out from under us by whatever the close path does to the editor.
    let editedText: String? = ForkStyle.isActive ? PreviewEditor.shared.effectiveText : nil

    AppState.shared.popup.close()
    copyToPasteboard(item, editedText: editedText, removeFormatting: removeFormatting)
    if paste {
      Clipboard.shared.paste()
    }

    if ForkStyle.isActive {
      PreviewEditor.shared.discard()
    }

    Task {
      searchQuery = ""
    }
  }

  @MainActor
  func startPasteStack(selection: inout Selection<HistoryItemDecorator>, flags modifierFlags: NSEvent.ModifierFlags) {
    guard AppState.shared.multiSelectionEnabled else { return }
    guard let item = selection.first else { return }
    PasteStack.initializeIfNeeded()

    let stack = PasteStack(items: selection.items, modifierFlags: modifierFlags)
    pasteStack = stack

    logger.info("Initialising PasteStack with \(stack.items.count) items")
    logger.info("Copying \(item.item.title) from PasteStack")

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .paste:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item)
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        Clipboard.shared.copy(item.item, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
    }

    Task {
      searchQuery = ""
    }
  }

  func handlePasteStack() {
    guard let stack = pasteStack else {
      return
    }

    guard let pasted = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("PasteStack pasted \(pasted.item.title)")

    stack.items.removeFirst()

    guard let item = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("Copying \(item.item.title) from PasteStack. \(stack.items.count) items remaining in stack.")

    Task {
      if stack.modifierFlags.isEmpty {
        await Clipboard.shared.copy(item.item, removeFormatting: Defaults[.removeFormattingByDefault])
      } else {
        switch HistoryItemAction(stack.modifierFlags) {
        case .copy:
          await Clipboard.shared.copy(item.item)
        case .paste:
          await Clipboard.shared.copy(item.item)
        case .pasteWithoutFormatting:
          await Clipboard.shared.copy(item.item, removeFormatting: true)
        case .unknown:
          return
        }
      }
    }
  }

  func interruptPasteStack() {
    guard pasteStack != nil else {
      return
    }
    logger.info("Interrupting PasteStack")
    pasteStack = nil
  }

  @MainActor
  func togglePin(_ item: HistoryItemDecorator?) {
    guard let item else { return }

    item.togglePin()

    let sortedItems = sorter.sort(all.map(\.item))
    if let currentIndex = all.firstIndex(of: item),
       let newIndex = sortedItems.firstIndex(of: item.item) {
      all.remove(at: currentIndex)
      all.insert(item, at: newIndex)
    }

    items = scopedItems()

    searchQuery = ""
    updateUnpinnedShortcuts()
    if item.isUnpinned {
      AppState.shared.navigator.scrollTarget = item.id
    }
  }

  @MainActor
  private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    if let duplicate = all.first(where: { $0.item != item && $0.item.supersedes(item) }) {
      return duplicate.item
    }

    return isModified(item)
  }

  private func isModified(_ item: HistoryItem) -> HistoryItem? {
    if let modified = item.modified, sessionLog.keys.contains(modified) {
      return sessionLog[modified]
    }

    return nil
  }

  private func updateItems(_ newItems: [Search.SearchResult]) {
    items = newItems.map { result in
      let item = result.object
      item.highlight(searchQuery, result.ranges)

      return item
    }

    updateUnpinnedShortcuts()
  }

  private func updateShortcuts() {
    for item in pinnedItems {
      if let pin = item.item.pin {
        item.shortcuts = KeyShortcut.create(character: pin)
      }
    }

    updateUnpinnedShortcuts()
  }

  @MainActor
  private func updateTitle(item: HistoryItemDecorator, title: String) {
    item.title = title
    item.item.title = title
  }

  private func updateUnpinnedShortcuts() {
    let visibleUnpinnedItems = unpinnedItems.filter(\.isVisible)
    for item in visibleUnpinnedItems {
      item.shortcuts = []
    }

    var index = 1
    for item in visibleUnpinnedItems.prefix(9) {
      item.shortcuts = KeyShortcut.create(character: String(index))
      index += 1
    }
  }
}
