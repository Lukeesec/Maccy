import Defaults
import Foundation
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  /// Store-side equivalent of `Sorter`'s ordering.
  ///
  /// `History` pages the store instead of fetching everything at launch, so the
  /// store has to hand back rows in the same order `Sorter` would put them in —
  /// otherwise page two is not the continuation of page one. Pinning is applied
  /// afterwards by `Sorter`, because pinned items are fetched separately and in
  /// full; this only covers `Defaults[.sortBy]`.
  nonisolated static func historySortDescriptors(by: Sorter.By = Defaults[.sortBy]) -> [SortDescriptor<HistoryItem>] {
    switch by {
    case .firstCopiedAt:
      return [SortDescriptor(\HistoryItem.firstCopiedAt, order: .reverse)]
    case .numberOfCopies:
      return [SortDescriptor(\HistoryItem.numberOfCopies, order: .reverse)]
    default:
      return [SortDescriptor(\HistoryItem.lastCopiedAt, order: .reverse)]
    }
  }

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).allValues.first?.value as? Int64, size > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: size)
  }

  private let url = URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")

  init() {
    var config = ModelConfiguration(url: url)

    #if DEBUG
    if AppDelegate.isTesting {
      config = ModelConfiguration(isStoredInMemoryOnly: true)
    }
    #endif

    do {
      container = try ModelContainer(for: HistoryItem.self, configurations: config)
    } catch let error {
      fatalError("Cannot load database: \(error.localizedDescription).")
    }
  }

  /// Every pinned item. There are at most a couple of dozen of these — the pin
  /// characters are a fixed alphabet — so they are always fetched in full and
  /// never paged, which keeps them correctly placed from the very first page.
  func fetchPinnedHistoryItems() throws -> [HistoryItem] {
    try context.fetch(
      FetchDescriptor<HistoryItem>(predicate: #Predicate<HistoryItem> { $0.pin != nil })
    )
  }

  /// One page of unpinned items in `Defaults[.sortBy]` order.
  func fetchUnpinnedHistoryItems(
    offset: Int,
    limit: Int,
    sortBy: [SortDescriptor<HistoryItem>] = Storage.historySortDescriptors()
  ) throws -> [HistoryItem] {
    var descriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate<HistoryItem> { $0.pin == nil },
      sortBy: sortBy
    )
    descriptor.fetchOffset = offset
    descriptor.fetchLimit = limit

    return try context.fetch(descriptor)
  }

  /// Items whose title contains `query`, answered by SQLite rather than by
  /// walking every decorator in memory.
  ///
  /// `localizedStandardContains` is case *and* diacritic insensitive, so the
  /// result is a superset of what `Search`'s case-insensitive `range(of:)` would
  /// match. That matters: callers use this only to narrow the candidate set and
  /// then run the real matcher over it, so a superset cannot change the answer.
  func fetchHistoryItems(titleContaining query: String) throws -> [HistoryItem] {
    try context.fetch(
      FetchDescriptor<HistoryItem>(
        predicate: #Predicate<HistoryItem> { $0.title.localizedStandardContains(query) }
      )
    )
  }

  func cleanupOrphanedContents() throws -> Int {
    let descriptor = FetchDescriptor<HistoryItemContent>(
      predicate: #Predicate { $0.item == nil }
    )
    let count = try context.fetchCount(descriptor)
    guard count > 0 else {
      return 0
    }

    try context.delete(
      model: HistoryItemContent.self,
      where: #Predicate { $0.item == nil }
    )
    context.processPendingChanges()
    try context.save()

    return count
  }

  // Titles stored before the sanitization in `HistoryItem.generateTitle()` may
  // contain scalars that hang CoreText on macOS 26. Such an item makes Maccy
  // spin at 100% CPU on every launch without ever drawing its window, so the
  // store has to be healed before the history is first rendered.
  // See https://github.com/p0deje/Maccy/issues/1520.
  func sanitizeTitles() throws -> Int {
    let items = try context.fetch(FetchDescriptor<HistoryItem>())
    var count = 0

    for item in items where item.title.containsScalarsUnsafeForTitleLayout {
      item.title = item.title.removingScalarsUnsafeForTitleLayout()
      count += 1
    }

    guard count > 0 else {
      return 0
    }

    context.processPendingChanges()
    try context.save()

    return count
  }
}
