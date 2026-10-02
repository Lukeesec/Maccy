import CryptoKit
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
      let batchSize = 200
      var offset = 0
      while true {
        // A fresh context releases relationship faults (scope classification)
        // after each batch instead of retaining the whole history in memory.
        let batchContext = ModelContext(container)
        var page = metadata
        page.fetchOffset = offset
        page.fetchLimit = batchSize
        let rows = try batchContext.fetch(page)
        for (position, item) in rows.enumerated() {
          guard scope.matchesUncached(item),
                let score = search.score(string: query, title: item.title, mode: mode) else { continue }
          matches.append((item.persistentModelID, score, item.pin != nil, offset + position))
        }
        offset += rows.count
        if rows.count < batchSize { break }
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

  func fetchDuplicateCandidates(title: String) throws -> [HistoryItem] {
    try context.fetch(FetchDescriptor<HistoryItem>(
      predicate: #Predicate<HistoryItem> { $0.title == title }
    ))
  }

  func populateMissingDuplicateFingerprints() throws {
    let batchSize = 100
    while true {
      let migrationContext = ModelContext(container)
      var descriptor = FetchDescriptor<HistoryItem>(
        predicate: #Predicate<HistoryItem> { $0.duplicateFingerprint == nil }
      )
      descriptor.fetchLimit = batchSize
      let missing = try migrationContext.fetch(descriptor)
      guard !missing.isEmpty else { return }
      for item in missing {
        // The empty sentinel prevents payload-free legacy rows from being
        // reprocessed on every launch.
        item.duplicateFingerprint = item.computeDuplicateFingerprint() ?? ""
      }
      migrationContext.processPendingChanges()
      try migrationContext.save()
    }
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


/// A portable archive of pasteboard representations, independent of SwiftData's
/// database schema. File URL representations remain references to those files.
struct HistoryArchive: Codable {
  var format = "org.p0deje.Maccy.history"
  var version = 1
  var exportedAt = Date.now
  var records: [Record]

  struct Content: Codable {
    var type: String
    var value: Data?
  }

  struct Record: Codable {
    var application: String?
    var firstCopiedAt: Date
    var lastCopiedAt: Date
    var numberOfCopies: Int
    var pin: String?
    var title: String
    var contents: [Content]

    @MainActor
    init(_ item: HistoryItem) {
      application = item.application
      firstCopiedAt = item.firstCopiedAt
      lastCopiedAt = item.lastCopiedAt
      numberOfCopies = item.numberOfCopies
      pin = item.pin
      title = item.title
      contents = item.contents.map { Content(type: $0.type, value: $0.value) }
    }

    /// All representations participate, including nil values. Rich and plain
    /// copies remain distinct so restoring cannot silently lose a payload.
    func contentKey() throws -> String {
      let ordered = contents.sorted { lhs, rhs in
        if lhs.type != rhs.type { return lhs.type < rhs.type }
        if lhs.value == nil { return rhs.value != nil }
        if rhs.value == nil { return false }
        return lhs.value!.lexicographicallyPrecedes(rhs.value!)
      }
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      return SHA256.hash(data: try encoder.encode(ordered)).map { String(format: "%02x", $0) }.joined()
    }
  }

  enum ArchiveError: LocalizedError {
    case invalidArchive
    case unsupportedVersion
    case noFreePins

    var errorDescription: String? {
      switch self {
      case .invalidArchive: return "This is not a valid Maccy history archive. No history was restored."
      case .unsupportedVersion: return "This archive requires a newer version of Maccy."
      case .noFreePins: return "There are not enough unused pin shortcuts to restore these clips. Unpin some clips and try again. No history was restored."
      }
    }
  }

  struct RestoreResult {
    var imported = 0
    var duplicates = 0
    var expired = 0
    var reassignedPins = 0
  }
}

extension Storage {
  func exportHistory() throws -> Data {
    try context.save()
    let snapshotContext = ModelContext(container)
    let rows = try snapshotContext.fetch(FetchDescriptor<HistoryItem>(sortBy: Self.historySortDescriptors()))
    let archive = HistoryArchive(records: rows.map(HistoryArchive.Record.init))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(archive)
  }

  /// Validate and allocate shortcuts before changing any models. Restore merges
  /// into the existing store; a single save commits the complete import.
  func restoreHistory(_ data: Data) throws -> HistoryArchive.RestoreResult {
    let archive: HistoryArchive
    do {
      archive = try JSONDecoder().decode(HistoryArchive.self, from: data)
    } catch {
      throw HistoryArchive.ArchiveError.invalidArchive
    }
    guard archive.format == "org.p0deje.Maccy.history" else {
      throw HistoryArchive.ArchiveError.invalidArchive
    }
    guard archive.version == 1 else { throw HistoryArchive.ArchiveError.unsupportedVersion }
    for record in archive.records {
      guard record.firstCopiedAt.timeIntervalSince1970.isFinite,
            record.lastCopiedAt.timeIntervalSince1970.isFinite,
            record.firstCopiedAt <= record.lastCopiedAt,
            record.numberOfCopies > 0,
            record.pin == nil || record.pin!.count == 1,
            record.contents.allSatisfy({ !$0.type.isEmpty && $0.type.utf8.count <= 1_024 }) else {
        throw HistoryArchive.ArchiveError.invalidArchive
      }
    }

    let stored = try context.fetch(FetchDescriptor<HistoryItem>())
    var existing: [String: HistoryItem] = [:]
    for item in stored {
      let key = try HistoryArchive.Record(item).contentKey()
      if existing[key] == nil || (existing[key]?.pin == nil && item.pin != nil) {
        existing[key] = item
      }
    }
    var usedPins = Set(stored.compactMap(\.pin))
    let supportedPins = HistoryItem.supportedPins
    let cutoff = Calendar.current.date(byAdding: .month, value: -max(1, Defaults[.retentionMonths]), to: .now)!
    var planned: [(record: HistoryArchive.Record, existing: HistoryItem?, pin: String?)] = []
    var result = HistoryArchive.RestoreResult()
    var aggregated: [String: HistoryArchive.Record] = [:]
    var keys: [String] = []
    for record in archive.records {
      let key = try record.contentKey()
      if var previous = aggregated[key] {
        previous.firstCopiedAt = min(previous.firstCopiedAt, record.firstCopiedAt)
        previous.lastCopiedAt = max(previous.lastCopiedAt, record.lastCopiedAt)
        previous.numberOfCopies = max(previous.numberOfCopies, record.numberOfCopies)
        previous.pin = previous.pin ?? record.pin
        aggregated[key] = previous
        result.duplicates += 1
      } else {
        aggregated[key] = record
        keys.append(key)
      }
    }

    for key in keys {
      let record = aggregated[key]!
      if record.pin == nil && record.lastCopiedAt < cutoff {
        result.expired += 1
        continue
      }
      let match = existing[key]
      var pin = match?.pin
      if pin == nil, let requested = record.pin {
        if supportedPins.contains(requested) && !usedPins.contains(requested) {
          pin = requested
        } else {
          pin = supportedPins.subtracting(usedPins).sorted().first
          guard pin != nil else { throw HistoryArchive.ArchiveError.noFreePins }
          result.reassignedPins += 1
        }
        usedPins.insert(pin!)
      }
      planned.append((record, match, pin))
      if match == nil { result.imported += 1 } else { result.duplicates += 1 }
    }

    // Persist any prior user action before starting the import transaction, so a
    // failed save rolls back only the restore operation.
    try context.save()
    do {
      for plan in planned {
        let record = plan.record
        if let item = plan.existing {
          item.firstCopiedAt = min(item.firstCopiedAt, record.firstCopiedAt)
          item.lastCopiedAt = max(item.lastCopiedAt, record.lastCopiedAt)
          item.numberOfCopies = max(item.numberOfCopies, record.numberOfCopies)
          item.pin = plan.pin
        } else {
          let item = HistoryItem(contents: record.contents.map { HistoryItemContent(type: $0.type, value: $0.value) })
          item.application = record.application
          item.firstCopiedAt = record.firstCopiedAt
          item.lastCopiedAt = record.lastCopiedAt
          item.numberOfCopies = record.numberOfCopies
          item.pin = plan.pin
          item.title = record.title.removingScalarsUnsafeForTitleLayout()
          item.duplicateFingerprint = item.computeDuplicateFingerprint() ?? ""
          context.insert(item)
        }
      }
      try context.save()
    } catch {
      context.rollback()
      throw error
    }
    return result
  }
}
