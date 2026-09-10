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
  // The rest arrives page by page without blocking the main actor.
  private static let firstPageSize = 60
  private static let pageSize = 120

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
    let pinned = (try? Storage.shared.fetchPinnedHistoryItems()) ?? []
    let firstPage = (try? Storage.shared.fetchUnpinnedHistoryItems(
      offset: 0,
      limit: Self.firstPageSize
    )) ?? []

    all = sorter.sort(pinned + firstPage).map { HistoryItemDecorator($0) }
    refreshItems(resetSelection: false)
    updateShortcuts()
    AppState.shared.popup.needsResize = true

    guard firstPage.count == Self.firstPageSize else {
      // The whole history fits in one page, so there is nothing to continue.
      limitHistorySize(to: Defaults[.size])
      updateShortcuts()
      return
    }

    loadTask = Task { @MainActor [weak self] in
      await self?.loadRemainder(from: Self.firstPageSize)
    }
  }

  /// Page in everything after the first page, yielding between pages so the
  /// popup stays responsive while it happens.
  @MainActor
  private func loadRemainder(from start: Int) async {
    var offset = start

    while !Task.isCancelled {
      await Task.yield()
      guard !Task.isCancelled else { return }

      guard let page = try? Storage.shared.fetchUnpinnedHistoryItems(
        offset: offset,
        limit: Self.pageSize
      ), !page.isEmpty else {
        break
      }

      offset += page.count
      merge(page)

      if page.count < Self.pageSize {
        break
      }
    }

    guard !Task.isCancelled else { return }

    limitHistorySize(to: Defaults[.size])
    updateShortcuts()
    AppState.shared.popup.needsResize = true
    loadTask = nil
  }

  /// Fold a freshly paged batch into `all`, keeping `Sorter`'s ordering.
  ///
  /// The batch is deduplicated against what is already loaded because a copy
  /// made mid-load shifts the store's offsets under us.
  @MainActor
  private func merge(_ page: [HistoryItem]) {
    let known = Set(all.map { ObjectIdentifier($0.item) })
    let fresh = page.filter { !known.contains(ObjectIdentifier($0)) }
    guard !fresh.isEmpty else { return }

    var decorators: [ObjectIdentifier: HistoryItemDecorator] = [:]
    for decorator in all {
      decorators[ObjectIdentifier(decorator.item)] = decorator
    }
    for item in fresh {
      decorators[ObjectIdentifier(item)] = HistoryItemDecorator(item)
    }

    all = sorter.sort(all.map(\.item) + fresh).compactMap { decorators[ObjectIdentifier($0)] }

    // Never steal the selection from someone who is already navigating or typing.
    refreshItems(resetSelection: false)
    AppState.shared.popup.needsResize = true
  }

  /// `all`, narrowed to the active scope. Identical to `all` on macOS 14 and 15,
  /// and whenever the scope is `.all`.
  @MainActor
  private func scopedItems() -> [HistoryItemDecorator] {
    guard ForkStyle.isActive, scope != .all else {
      return all
    }

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
    guard let item else {
      return
    }

    // Read the draft before anything closes the popup, so it cannot be discarded
    // out from under us by whatever the close path does to the editor.
    let editedText: String? = ForkStyle.isActive ? PreviewEditor.shared.effectiveText : nil

    if modifierFlags.isEmpty {
      AppState.shared.popup.close()
      copyToPasteboard(
        item,
        editedText: editedText,
        removeFormatting: Defaults[.removeFormattingByDefault]
      )
      if Defaults[.pasteByDefault] {
        Clipboard.shared.paste()
      }
    } else {
      switch HistoryItemAction(modifierFlags) {
      case .copy:
        AppState.shared.popup.close()
        copyToPasteboard(item, editedText: editedText, removeFormatting: false)
      case .paste:
        AppState.shared.popup.close()
        copyToPasteboard(item, editedText: editedText, removeFormatting: false)
        Clipboard.shared.paste()
      case .pasteWithoutFormatting:
        AppState.shared.popup.close()
        copyToPasteboard(item, editedText: editedText, removeFormatting: true)
        Clipboard.shared.paste()
      case .unknown:
        return
      }
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
