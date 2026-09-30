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
      pageIndex = 0
      searchCacheKey = nil

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
      pageIndex = 0
      searchCacheKey = nil

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

  private let search = Search()
  private let sorter = Sorter()
  private let throttler = Throttler(minimumDelay: 0.2)

  @ObservationIgnored
  private var sessionLog: [Int: HistoryItem] = [:]

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
      for await _ in Defaults.updates(.size, initial: false) {
        try? await load()
      }
    }

    Task {
      for await _ in Defaults.updates(.retentionMonths, initial: false) {
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

  private struct SearchCacheKey: Equatable {
    let query: String
    let scope: ForkScope
    let mode: Search.Mode
    let sortBy: Sorter.By
  }

  @ObservationIgnored private var searchCacheKey: SearchCacheKey?
  @ObservationIgnored private var searchMatchIDs: [PersistentIdentifier] = []
  @ObservationIgnored private var expiryTask: Task<Void, Never>?

  var pageIndex = 0
  var totalUnpinnedCount = 0
  var pageCount: Int {
    let total = searchQuery.isEmpty && scope == .all ? totalUnpinnedCount : searchMatchIDs.count
    let pageSize = max(1, Defaults[.size])
    return max(1, (total + pageSize - 1) / pageSize)
  }
  var hasNewerPage: Bool { pageIndex > 0 }
  var hasOlderPage: Bool {
    let total = searchQuery.isEmpty && scope == .all ? totalUnpinnedCount : searchMatchIDs.count
    return (pageIndex + 1) * max(1, Defaults[.size]) < total
  }

  @MainActor
  func load() async throws {
    try expireOldHistory()
    try Storage.shared.populateMissingDuplicateFingerprints()
    searchCacheKey = nil
    pageIndex = 0
    try loadBrowsePage()

    if expiryTask == nil {
      expiryTask = Task { @MainActor [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .seconds(86_400))
          guard !Task.isCancelled, let self else { return }
          do {
            try self.expireOldHistory()
            try self.loadBrowsePage()
          } catch {
            self.logger.error("Failed to expire history: \(String(reflecting: error))")
          }
        }
      }
    }
  }

  @MainActor
  private func expireOldHistory() throws {
    let months = max(1, Defaults[.retentionMonths])
    guard let cutoff = Calendar.current.date(byAdding: .month, value: -months, to: .now) else { return }
    let removed = try Storage.shared.pruneExpiredHistory(before: cutoff)
    if removed > 0 {
      searchCacheKey = nil
    }
  }

  @MainActor
  private func loadBrowsePage() throws {
    let pageSize = max(1, Defaults[.size])
    totalUnpinnedCount = try Storage.shared.countUnpinnedHistoryItems()
    if pageIndex * pageSize >= totalUnpinnedCount && pageIndex > 0 {
      pageIndex = max(0, (totalUnpinnedCount - 1) / pageSize)
    }
    let pinned = try Storage.shared.fetchPinnedHistoryItems()
    let unpinned = try Storage.shared.fetchUnpinnedPage(
      offset: pageIndex * pageSize,
      limit: pageSize
    )
    var existing: [PersistentIdentifier: HistoryItemDecorator] = [:]
    for decorator in all + items {
      existing[decorator.item.persistentModelID] = decorator
    }
    all = sorter.sort(pinned + unpinned).map { item in
      existing[item.persistentModelID] ?? HistoryItemDecorator(item)
    }
    refreshItems(resetSelection: false)
    updateShortcuts()
    AppState.shared.popup.needsResize = true
  }

  @MainActor
  func showOlderPage() {
    guard hasOlderPage else { return }
    pageIndex += 1
    if searchQuery.isEmpty && scope == .all {
      try? loadBrowsePage()
    } else {
      refreshItems(resetSelection: true)
    }
    AppState.shared.navigator.select()
  }

  @MainActor
  func showNewerPage() {
    guard hasNewerPage else { return }
    pageIndex -= 1
    if searchQuery.isEmpty && scope == .all {
      try? loadBrowsePage()
    } else {
      refreshItems(resetSelection: true)
    }
    AppState.shared.navigator.select()
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

  /// The browse page stays small; a query instead searches the complete store
  /// and materializes only the selected page of matches.
  @MainActor
  private func searchCandidates() -> [HistoryItemDecorator] {
    guard !searchQuery.isEmpty || (ForkStyle.isActive && scope != .all) else {
      return all
    }

    let key = SearchCacheKey(
      query: searchQuery, scope: scope, mode: Defaults[.searchMode], sortBy: Defaults[.sortBy]
    )
    if searchCacheKey != key {
      do {
        searchMatchIDs = try Storage.shared.searchHistoryIdentifiers(query: searchQuery, scope: scope)
        searchCacheKey = key
        pageIndex = 0
      } catch {
        logger.error("Failed to search history: \(String(reflecting: error))")
        return scopedItems()
      }
    }

    let pageSize = max(1, Defaults[.size])
    let start = pageIndex * pageSize
    guard start < searchMatchIDs.count else { return [] }
    let end = min(start + pageSize, searchMatchIDs.count)
    var visible: [PersistentIdentifier: HistoryItemDecorator] = [:]
    for decorator in all + items {
      visible[decorator.item.persistentModelID] = decorator
    }
    return searchMatchIDs[start..<end].compactMap { id in
      if let existing = visible[id] { return existing }
      guard let item = Storage.shared.context.model(for: id) as? HistoryItem else { return nil }
      return HistoryItemDecorator(item)
    }
  }

  /// The single place `items` is recomputed from `all`, the scope and the query.
  @MainActor
  private func refreshItems(resetSelection: Bool) {
    updateItems(search.search(string: searchQuery, within: searchCandidates()))

    guard resetSelection else { return }

    if ForkStyle.isActive, !AppState.shared.historyNavigationActive {
      // Typing puts keyboard focus back on the search row. Keep the visible
      // selection in sync rather than painting a result as selected too.
      AppState.shared.navigator.select()
    } else if searchQuery.isEmpty {
      AppState.shared.navigator.select(item: unpinnedItems.first)
    } else {
      AppState.shared.navigator.highlightFirst()
    }

    AppState.shared.popup.needsResize = true
  }

  @MainActor
  func insertIntoStorage(_ item: HistoryItem) throws {
    logger.info("Inserting history item")
    Storage.shared.context.insert(item)
    Storage.shared.context.processPendingChanges()
    try Storage.shared.context.save()
  }

  @discardableResult
  @MainActor
  func add(_ item: HistoryItem) -> HistoryItemDecorator {
    item.duplicateFingerprint = item.computeDuplicateFingerprint()
    do {
      if #available(macOS 15.0, *) {
        try insertIntoStorage(item)
      } else {
        // Clipboard inserted the model before its pasteboard data was finalized.
        try Storage.shared.context.save()
      }
    } catch {
      logger.error("Failed to persist history item: \(String(reflecting: error))")
      Storage.shared.context.rollback()
      return HistoryItemDecorator(item)
    }

    let existing = findSimilarItem(item)
    if let existing {
      if isModified(item) == nil {
        transferContents(from: existing, to: item)
      }
      item.firstCopiedAt = existing.firstCopiedAt
      item.numberOfCopies += existing.numberOfCopies
      item.pin = existing.pin
      item.title = existing.title
      item.duplicateFingerprint = item.computeDuplicateFingerprint()
      if !item.fromMaccy {
        item.application = existing.application
      }
      deleteFromStorage(existing)
      do {
        Storage.shared.context.processPendingChanges()
        try Storage.shared.context.save()
      } catch {
        logger.error("Failed to merge duplicate history item: \(String(reflecting: error))")
        Storage.shared.context.rollback()
        try? loadBrowsePage()
        return HistoryItemDecorator(item)
      }
      logger.info("Removed duplicate history item")
    } else {
      Task { Notifier.notify(body: item.title, sound: .write) }
    }

    sessionLog[Clipboard.shared.changeCount] = item
    searchCacheKey = nil
    totalUnpinnedCount = (try? Storage.shared.countUnpinnedHistoryItems()) ?? totalUnpinnedCount

    if pageIndex > 0 {
      pageIndex = 0
      try? loadBrowsePage()
      return all.first(where: { $0.item == item }) ?? HistoryItemDecorator(item)
    }

    if let existing {
      if let removed = all.first(where: { $0.item == existing }) {
        cleanup(removed)
      }
      all.removeAll { $0.item == existing }
    }

    let decorator = HistoryItemDecorator(item)
    let sorted = sorter.sort(all.map(\.item) + [item])
    if let index = sorted.firstIndex(of: item) {
      all.insert(decorator, at: index)
    }

    // Evict from the browse page only. The database retains the row until age
    // expiry, and search can still find it across the complete history.
    let pageSize = max(1, Defaults[.size])
    let overflow = Array(all.filter(\.isUnpinned).dropFirst(pageSize))
    for old in overflow { cleanup(old) }
    let overflowIDs = Set(overflow.map(\.id))
    all.removeAll { overflowIDs.contains($0.id) }

    refreshItems(resetSelection: false)
    AppState.shared.popup.needsResize = true
    return decorator
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
      items.removeAll(where: \.isUnpinned)
      searchCacheKey = nil
      searchMatchIDs = []
      pageIndex = 0
      totalUnpinnedCount = 0

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
      items.removeAll()
      searchCacheKey = nil
      searchMatchIDs = []
      pageIndex = 0
      totalUnpinnedCount = 0

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

    searchCacheKey = nil
    if searchQuery.isEmpty && scope == .all {
      try? loadBrowsePage()
    } else {
      refreshItems(resetSelection: false)
    }

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
    logger.info("Copying item from PasteStack")

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

    logger.info("PasteStack pasted item")

    stack.items.removeFirst()

    guard let item = stack.items.first else {
      pasteStack = nil
      logger.info("PasteStack is empty")
      return
    }

    logger.info("Copying item from PasteStack. \(stack.items.count) items remaining in stack.")

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
    try? Storage.shared.context.save()
    searchCacheKey = nil
    pageIndex = 0
    try? loadBrowsePage()
    searchQuery = ""
    updateUnpinnedShortcuts()
    if item.isUnpinned {
      AppState.shared.navigator.scrollTarget = item.id
    }
  }

  @MainActor
  private func findSimilarItem(_ item: HistoryItem) -> HistoryItem? {
    if let modified = isModified(item) { return modified }

    if let fingerprint = item.duplicateFingerprint,
       let candidates = try? Storage.shared.fetchDuplicateCandidates(fingerprint: fingerprint),
       let duplicate = candidates.first(where: { $0 != item && $0.supersedes(item) }) {
      return duplicate
    }

    if let duplicate = all.first(where: { $0.item != item && $0.item.supersedes(item) }) {
      return duplicate.item
    }

    return nil
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
