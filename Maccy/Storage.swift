import Defaults
import Foundation
import SwiftData

@MainActor
class Storage {
  static let shared = Storage()

  struct UsageSnapshot {
    let itemCount: Int
    let oldest: Date?
    let newest: Date?
    let diskBytes: Int64
  }

  /// Store-side equivalent of `Sorter`'s ordering.
  ///
  /// Pages need a deterministic order, especially when thousands of items have
  /// the same copy count. Pinning is applied afterwards by `Sorter`.
  nonisolated static func historySortDescriptors(by: Sorter.By = Defaults[.sortBy]) -> [SortDescriptor<HistoryItem>] {
    switch by {
    case .firstCopiedAt:
      return [
        SortDescriptor(\HistoryItem.firstCopiedAt, order: .reverse),
        SortDescriptor(\HistoryItem.lastCopiedAt, order: .reverse)
      ]
    case .numberOfCopies:
      return [
        SortDescriptor(\HistoryItem.numberOfCopies, order: .reverse),
        SortDescriptor(\HistoryItem.lastCopiedAt, order: .reverse)
      ]
    default:
      return [
        SortDescriptor(\HistoryItem.lastCopiedAt, order: .reverse),
        SortDescriptor(\HistoryItem.firstCopiedAt, order: .reverse)
      ]
    }
  }

  var container: ModelContainer
  var context: ModelContext { container.mainContext }
  var size: String {
    let bytes = diskBytes
    guard bytes > 1 else {
      return ""
    }

    return ByteCountFormatter().string(fromByteCount: bytes)
  }

  private let url = URL.applicationSupportDirectory.appending(path: "Maccy/Storage.sqlite")

  private var diskBytes: Int64 {
    [url.path, url.path + "-wal", url.path + "-shm"].reduce(0) { total, path in
      let attributes = try? FileManager.default.attributesOfItem(atPath: path)
      return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
    }
  }

  func usageSnapshot() -> UsageSnapshot {
    let count = (try? context.fetchCount(FetchDescriptor<HistoryItem>())) ?? 0
    var oldestDescriptor = FetchDescriptor<HistoryItem>(
      sortBy: [SortDescriptor(\HistoryItem.lastCopiedAt)]
    )
    oldestDescriptor.fetchLimit = 1
    var newestDescriptor = FetchDescriptor<HistoryItem>(
      sortBy: [SortDescriptor(\HistoryItem.lastCopiedAt, order: .reverse)]
    )
    newestDescriptor.fetchLimit = 1
    return UsageSnapshot(
      itemCount: count,
      oldest: try? context.fetch(oldestDescriptor).first?.lastCopiedAt,
      newest: try? context.fetch(newestDescriptor).first?.lastCopiedAt,
      diskBytes: diskBytes
    )
  }

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

  func countUnpinnedHistoryItems() throws -> Int {
    try context.fetchCount(FetchDescriptor<HistoryItem>(
      predicate: #Predicate<HistoryItem> { $0.pin == nil }
    ))
  }

  func fetchUnpinnedPage(offset: Int, limit: Int, sortBy: Sorter.By = Defaults[.sortBy]) throws -> [HistoryItem] {
    var descriptor = FetchDescriptor<HistoryItem>(
      predicate: #Predicate<HistoryItem> { $0.pin == nil },
      sortBy: Self.historySortDescriptors(by: sortBy)
    )
    descriptor.fetchOffset = max(0, offset)
    descriptor.fetchLimit = max(1, limit)
    return try context.fetch(descriptor)
  }

  /// Age is measured from the last copy. Pins are kept until explicitly removed.
  func pruneExpiredHistory(before cutoff: Date) throws -> Int {
    let expired = FetchDescriptor<HistoryItem>(
      predicate: #Predicate<HistoryItem> { $0.pin == nil && $0.lastCopiedAt < cutoff }
    )
    let count = try context.fetchCount(expired)
    guard count > 0 else { return 0 }

    try context.delete(model: HistoryItem.self, where: #Predicate {
      $0.pin == nil && $0.lastCopiedAt < cutoff
    })
    context.processPendingChanges()
    try context.save()
    _ = try cleanupOrphanedContents()
    return count
  }

  /// Search all retained rows through a disposable context. Only scalar
  /// metadata is fetched for the common unscoped case; visible rows are later
  /// resolved in the main context one page at a time.
  func searchHistoryIdentifiers(query: String, scope: ForkScope) throws -> [PersistentIdentifier] {
    let selectedMode = Defaults[.searchMode]
    let passes: [Search.Mode] = selectedMode == .mixed
      ? [.exact, .regexp, .fuzzy] : [selectedMode]
    let search = Search()

    for mode in passes {
      let scanContext = ModelContext(container)
      let descriptor: FetchDescriptor<HistoryItem>
      if mode == .exact, !query.isEmpty {
        let needle = query
        descriptor = FetchDescriptor<HistoryItem>(
          predicate: #Predicate<HistoryItem> { $0.title.localizedStandardContains(needle) },
          sortBy: Self.historySortDescriptors()
        )
      } else {
        descriptor = FetchDescriptor<HistoryItem>(sortBy: Self.historySortDescriptors())
      }
      var metadata = descriptor
      metadata.propertiesToFetch = [
        \HistoryItem.title, \HistoryItem.pin, \HistoryItem.lastCopiedAt,
        \HistoryItem.firstCopiedAt, \HistoryItem.numberOfCopies
      ]

      var matches: [(id: PersistentIdentifier, score: Double, pinned: Bool, index: Int)] = []
      for (index, item) in try scanContext.fetch(metadata).enumerated() {
        guard scope.matchesUncached(item),
              let score = search.score(string: query, title: item.title, mode: mode) else { continue }
        matches.append((item.persistentModelID, score, item.pin != nil, index))
      }
      guard !matches.isEmpty else { continue }

      if mode == .fuzzy {
        matches.sort { $0.score == $1.score ? $0.index < $1.index : $0.score < $1.score }
      } else {
        let pinsFirst = Defaults[.pinTo] == .top
        matches.sort { lhs, rhs in
          if lhs.pinned != rhs.pinned { return pinsFirst ? lhs.pinned : !lhs.pinned }
          return lhs.index < rhs.index
        }
      }
      return matches.map { $0.id }
    }

    return []
  }

  func fetchDuplicateCandidates(fingerprint: String) throws -> [HistoryItem] {
    try context.fetch(FetchDescriptor<HistoryItem>(
      predicate: #Predicate<HistoryItem> { $0.duplicateFingerprint == fingerprint }
    ))
  }

  func populateMissingDuplicateFingerprints() throws {
    let missing = try context.fetch(FetchDescriptor<HistoryItem>(
      predicate: #Predicate<HistoryItem> { $0.duplicateFingerprint == nil }
    ))
    guard !missing.isEmpty else { return }
    for item in missing {
      item.duplicateFingerprint = item.computeDuplicateFingerprint()
    }
    context.processPendingChanges()
    try context.save()
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
