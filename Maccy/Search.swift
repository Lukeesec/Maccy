import AppKit
import Defaults
import Fuse

class Search {
  enum Mode: String, CaseIterable, Identifiable, CustomStringConvertible, Defaults.Serializable {
    case exact
    case fuzzy
    case regexp
    case mixed

    var id: Self { self }

    var description: String {
      switch self {
      case .exact:
        return NSLocalizedString("Exact", tableName: "GeneralSettings", comment: "")
      case .fuzzy:
        return NSLocalizedString("Fuzzy", tableName: "GeneralSettings", comment: "")
      case .regexp:
        return NSLocalizedString("Regex", tableName: "GeneralSettings", comment: "")
      case .mixed:
        return NSLocalizedString("Mixed", tableName: "GeneralSettings", comment: "")
      }
    }
  }

  struct SearchResult: Equatable {
    var score: Double?
    var object: Searchable
    var ranges: [Range<String.Index>] = []
  }

  typealias Searchable = HistoryItemDecorator

  /// True when a case-insensitive substring prefilter is guaranteed to return a
  /// *superset* of what `mode` matches, and can therefore be pushed into the
  /// store without changing a single result.
  ///
  /// Only `.exact` qualifies:
  /// - `.regexp` — `foo|bar` or `^x` are not substrings of anything; SQLite has
  ///   no regex operator to push down either.
  /// - `.fuzzy` — the whole point of fuzzy matching is finding titles that do
  ///   *not* contain the query (`hlo` → `hello`). See `prescreen(_:_:)` for how
  ///   fuzzy mode is made fast instead.
  /// - `.mixed` — falls back to regex and then fuzzy when the exact pass comes
  ///   up empty, so narrowing its input would break both fallbacks.
  static func canNarrowInStore(_ mode: Mode) -> Bool {
    mode == .exact
  }

  private let fuse = Fuse(threshold: 0.7) // threshold found by trial-and-error
  private let fuzzySearchLimit = 5_000

  // Fraction of the query's distinct alphanumerics that must appear somewhere in
  // a title for it to be worth handing to Fuse. Fuse's 0.7 threshold tolerates a
  // lot of noise, so this is deliberately generous — it is a cheap way to skip
  // the titles that share almost nothing with the query, not a matcher.
  private static let prescreenCoverage = 0.4

  // Character-set bitmask per decorator, so a keystroke costs one 64-bit AND per
  // item instead of a bitap pass over the whole title. Keyed by identity and
  // validated against the title it was built from, because a title can change
  // under a decorator (text recognition on images fills it in asynchronously).
  private var maskCache: [ObjectIdentifier: (title: String, mask: UInt64)] = [:]

  func search(string: String, within: [Searchable]) -> [SearchResult] {
    guard !string.isEmpty else {
      return within.map { SearchResult(object: $0) }
    }

    switch Defaults[.searchMode] {
    case .mixed:
      return mixedSearch(string: string, within: within)
    case .regexp:
      return simpleSearch(string: string, within: within, options: .regularExpression)
    case .fuzzy:
      return fuzzySearch(string: string, within: within)
    default:
      return simpleSearch(string: string, within: within, options: .caseInsensitive)
    }
  }

  private func fuzzySearch(string: String, within: [Searchable]) -> [SearchResult] {
    let pattern = fuse.createPattern(from: string)
    let candidates = ForkStyle.isActive ? prescreen(string, within) : within
    let searchResults: [SearchResult] = candidates.compactMap { item in
      fuzzySearch(for: pattern, in: item.title, of: item)
    }
    let sortedResults = searchResults.sorted(by: { ($0.score ?? 0) < ($1.score ?? 0) })
    return sortedResults
  }

  /// Drop the titles that cannot plausibly fuzzy-match `query` before Fuse ever
  /// sees them.
  ///
  /// Fuse runs a bitap over every character of every title on every keystroke.
  /// The prescreen replaces that with a cached 64-bit character-set mask per
  /// title and a single AND per item: a title that contains fewer than
  /// `prescreenCoverage` of the query's distinct alphanumerics is skipped.
  ///
  /// Unlike a substring prefilter this keeps fuzzy matching genuinely fuzzy —
  /// characters may be out of order, interleaved with anything, or missing.
  /// It is a heuristic rather than a proof: an extreme query (over 60% of its
  /// characters absent from the title) that Fuse would still have scored under
  /// its 0.7 threshold is dropped. Queries like that match nearly everything, so
  /// nothing useful is lost.
  private func prescreen(_ query: String, _ within: [Searchable]) -> [Searchable] {
    let queryMask = Self.characterMask(query)
    // Nothing to compare against - a query of CJK, emoji or punctuation only.
    guard queryMask != 0 else {
      return within
    }

    let required = max(1, Int((Double(queryMask.nonzeroBitCount) * Self.prescreenCoverage).rounded(.up)))

    if maskCache.count > max(within.count * 2, 256) {
      maskCache.removeAll(keepingCapacity: true)
    }

    return within.filter { item in
      let key = ObjectIdentifier(item)
      let title = item.title
      let mask: UInt64

      if let cached = maskCache[key], cached.title == title {
        mask = cached.mask
      } else {
        mask = Self.characterMask(title)
        maskCache[key] = (title, mask)
      }

      return (mask & queryMask).nonzeroBitCount >= required
    }
  }

  /// Bit per distinct ASCII alphanumeric present, case folded: a-z in 0..<26,
  /// 0-9 in 26..<36. Everything else, including every byte of a multi-byte
  /// scalar, is ignored — which only ever makes the mask smaller, and a smaller
  /// query mask means a lower bar, never a dropped candidate.
  private static func characterMask(_ string: String) -> UInt64 {
    var mask: UInt64 = 0

    for byte in string.utf8 {
      switch byte {
      case 0x61...0x7A: // a-z
        mask |= UInt64(1) << UInt64(byte - 0x61)
      case 0x41...0x5A: // A-Z
        mask |= UInt64(1) << UInt64(byte - 0x41)
      case 0x30...0x39: // 0-9
        mask |= UInt64(1) << UInt64(26 + (byte - 0x30))
      default:
        break
      }
    }

    return mask
  }

  private func fuzzySearch(
    for pattern: Fuse.Pattern?,
    in searchString: String,
    of item: Searchable
  ) -> SearchResult? {
    var searchString = searchString
    if searchString.count > fuzzySearchLimit {
      // shortcut to avoid slow search
      let stopIndex = searchString.index(searchString.startIndex, offsetBy: fuzzySearchLimit)
      searchString = "\(searchString[...stopIndex])"
    }

    if let fuzzyResult = fuse.search(pattern, in: searchString) {
      return SearchResult(
        score: fuzzyResult.score,
        object: item,
        ranges: fuzzyResult.ranges.map {
          let startIndex = searchString.startIndex
          let lowerBound = searchString.index(startIndex, offsetBy: $0.lowerBound)
          let upperBound = searchString.index(startIndex, offsetBy: $0.upperBound + 1)

          return lowerBound..<upperBound
        }
      )
    } else {
      return nil
    }
  }

  private func simpleSearch(
    string: String,
    within: [Searchable],
    options: NSString.CompareOptions
  ) -> [SearchResult] {
    return within.compactMap { simpleSearch(for: string, in: $0.title, of: $0, options: options) }
  }

  private func simpleSearch(
    for string: String,
    in searchString: String,
    of item: Searchable,
    options: NSString.CompareOptions
  ) -> SearchResult? {
    if let range = searchString.range(of: string, options: options, range: nil, locale: nil) {
      return SearchResult(object: item, ranges: [range])
    } else {
      return nil
    }
  }

  private func mixedSearch(string: String, within: [Searchable]) -> [SearchResult] {
    var results = simpleSearch(string: string, within: within, options: .caseInsensitive)
    guard results.isEmpty else {
      return results
    }

    results = simpleSearch(string: string, within: within, options: .regularExpression)
    guard results.isEmpty else {
      return results
    }

    results = fuzzySearch(string: string, within: within)
    guard results.isEmpty else {
      return results
    }

    return []
  }
}
