import Defaults
import Foundation
import SwiftData

/// Where a page of unpinned history resumes from.
///
/// A *value*, not a position. `descriptor.fetchOffset` cannot be used to page
/// this store because the store is written to while the paging runs:
/// `History.add()` deletes the row it consolidates a duplicate into,
/// `History.delete()` removes whatever the user picked, and `limitHistorySize`
/// trims the tail. Every delete below the current offset shifts the remaining
/// rows up by one, so the reader steps over exactly one row and never sees it
/// again — and `limitHistorySize` then trims against an undercount.
///
/// A keyset cursor carries the last row's sort key instead, so the next page
/// resumes from the same place regardless of what was inserted or removed
/// elsewhere. All three of `Sorter.By`'s keys are carried because the cursor is
/// built before the sort order is known to the caller, and because the
/// tiebreaker for one order is the primary key of another.
struct HistoryPageCursor: Equatable, Sendable {
  var lastCopiedAt: Date
  var firstCopiedAt: Date
  var numberOfCopies: Int

  init(_ item: HistoryItem) {
    lastCopiedAt = item.lastCopiedAt
    firstCopiedAt = item.firstCopiedAt
    numberOfCopies = item.numberOfCopies
  }
}

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
  ///
  /// The second descriptor is a tiebreaker, and is what makes keyset paging
  /// work. `numberOfCopies` in particular is shared by thousands of rows, and a
  /// cursor cannot resume inside a block of rows whose order is undefined. The
  /// tiebreaker is the other timestamp, which is effectively unique per item,
  /// so the pair orders the store totally. `Sorter` has no tiebreaker, but it
  /// sorts with a stable sort over exactly these rows in exactly this order, so
  /// it preserves whatever the store decided.
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

  /// One page of unpinned items in `Defaults[.sortBy]` order, resuming from
  /// `cursor` — or from the very top when it is `nil`.
  ///
  /// There is no `fetchOffset` here on purpose; see `HistoryPageCursor` for why
  /// an offset loses rows against a store that is being written to while it is
  /// read.
  func fetchUnpinnedHistoryItems(
    after cursor: HistoryPageCursor?,
    limit: Int,
    sortBy: Sorter.By = Defaults[.sortBy]
  ) throws -> [HistoryItem] {
    var descriptor = FetchDescriptor<HistoryItem>(
      predicate: Self.unpinnedPredicate(after: cursor, sortBy: sortBy),
      sortBy: Self.historySortDescriptors(by: sortBy)
    )
    descriptor.fetchLimit = limit

    return try context.fetch(descriptor)
  }

  /// Unpinned rows at or after `cursor` in `sortBy` order.
  ///
  /// The bound is strict on the primary key and *inclusive* on the tiebreaker.
  /// That is deliberate: an inclusive tiebreaker re-reads the cursor row itself
  /// — one row per page, which the caller's dedupe drops — but it also cannot
  /// skip a row that happens to share both keys with the cursor. An exclusive
  /// bound would silently lose such a row; there is no ordering to fall back on
  /// once both keys are equal, because `PersistentIdentifier` is not
  /// `Comparable` and so cannot be used as a third bound inside a `#Predicate`.
  nonisolated private static func unpinnedPredicate(
    after cursor: HistoryPageCursor?,
    sortBy: Sorter.By
  ) -> Predicate<HistoryItem> {
    guard let cursor else {
      return #Predicate<HistoryItem> { $0.pin == nil }
    }

    switch sortBy {
    case .firstCopiedAt:
      let key = cursor.firstCopiedAt
      let tiebreaker = cursor.lastCopiedAt
      return #Predicate<HistoryItem> {
        $0.pin == nil &&
          ($0.firstCopiedAt < key || ($0.firstCopiedAt == key && $0.lastCopiedAt <= tiebreaker))
      }
    case .numberOfCopies:
      let key = cursor.numberOfCopies
      let tiebreaker = cursor.lastCopiedAt
      return #Predicate<HistoryItem> {
        $0.pin == nil &&
          ($0.numberOfCopies < key || ($0.numberOfCopies == key && $0.lastCopiedAt <= tiebreaker))
      }
    default:
      let key = cursor.lastCopiedAt
      let tiebreaker = cursor.firstCopiedAt
      return #Predicate<HistoryItem> {
        $0.pin == nil &&
          ($0.lastCopiedAt < key || ($0.lastCopiedAt == key && $0.firstCopiedAt <= tiebreaker))
      }
    }
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
