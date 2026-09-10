import AppKit
import Defaults
import Foundation

/// A Spotlight-style scope filter for the clipboard list.
///
/// macOS 26 Spotlight narrows its results with typed tokens such as `/pdf`.
/// `ForkScope` is the same idea applied to clipboard history: the list can be
/// restricted to text, links, images or files, either from the scope picker or
/// by typing the scope's `token` after a slash.
///
/// The filter is part of the Spotlight redesign, so `History` only applies it
/// when `ForkStyle.isActive`. On macOS 14 and 15 the scope is inert and the list
/// behaves exactly like upstream's.
enum ForkScope: String, CaseIterable, Identifiable, Defaults.Serializable {
  case all
  case text
  case links
  case images
  case files

  var id: Self { self }

  /// The token typed in the search field, without the leading slash.
  var token: String {
    switch self {
    case .all: return "all"
    case .text: return "text"
    case .links: return "link"
    case .images: return "img"
    case .files: return "file"
    }
  }

  /// Localized display name for the picker and the chip.
  ///
  /// The keys live in `Localizable.strings`, which this file deliberately does
  /// not own — the strings are added alongside the scope UI.
  var title: String {
    switch self {
    case .all: return NSLocalizedString("scope_all", comment: "")
    case .text: return NSLocalizedString("scope_text", comment: "")
    case .links: return NSLocalizedString("scope_links", comment: "")
    case .images: return NSLocalizedString("scope_images", comment: "")
    case .files: return NSLocalizedString("scope_files", comment: "")
    }
  }

  /// SF Symbol name for the picker and the chip.
  var symbol: String {
    switch self {
    case .all: return "square.grid.2x2"
    case .text: return "textformat"
    case .links: return "link"
    case .images: return "photo"
    case .files: return "doc"
    }
  }

  /// The scope a typed token names, with or without its leading slash.
  /// Returns `nil` when nothing matches, so the caller can leave the text alone.
  static func named(_ token: String) -> ForkScope? {
    var needle = Substring(token)
    if needle.hasPrefix("/") {
      needle = needle.dropFirst()
    }
    guard !needle.isEmpty else { return nil }

    return allCases.first { $0.token.caseInsensitiveCompare(String(needle)) == .orderedSame }
  }

  /// True when the item belongs to this scope.
  ///
  /// Classification comes from `ForkItemKind`, which reads the item's stored
  /// pasteboard types, and is memoised per item. This used to ask
  /// `item.image != nil`, which decodes `imageData` into an `NSImage` and parks
  /// it in a `@Transient` cache — so filtering to Text or Images decoded and
  /// then permanently retained every image in the store. `.files` and `.text`
  /// asked `item.fileURLs`, which re-runs `allContentData([.fileURL])` plus URL
  /// parsing on every call and is not cached at all. Both ran for every item on
  /// every `refreshItems`: every throttled keystroke, and every paged merge.
  @MainActor
  func matches(_ item: HistoryItem) -> Bool {
    guard self != .all else {
      return true
    }

    let kind = ForkItemKindCache.kind(of: item)

    switch self {
    case .all:
      return true
    case .images:
      return kind.hasImage
    case .files:
      return kind.hasFiles
    case .links:
      return kind.isLink
    case .text:
      return !kind.hasImage && !kind.hasFiles
    }
  }

  /// A title is treated as a link when it is nothing but an http(s) URL.
  /// Anything with whitespace in it is prose that happens to start with a URL.
  fileprivate static func isLink(_ title: String) -> Bool {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
      return false
    }

    return !trimmed.contains(where: \.isWhitespace)
  }
}

/// What a history item *is*, decided from the pasteboard types it carries
/// rather than from its decoded content.
///
/// Nothing here materialises an `NSImage`, reads a file, or parses a URL on the
/// path any normal item takes — the only exception is a Universal Clipboard
/// image, which has no image type of its own and can only be recognised by the
/// extension on its transfer file. Those are rare, and this runs once per item
/// rather than once per keystroke.
struct ForkItemKind: Equatable {
  /// The item carries image data. Matches `HistoryItem.imageData != nil`, which
  /// is what `image` decodes — a payload that fails to decode into an `NSImage`
  /// now counts as an image where it previously counted as text.
  var hasImage: Bool
  /// The item carries file URLs, under the same Universal Clipboard exclusion
  /// `HistoryItem.fileURLs` applies.
  var hasFiles: Bool
  /// The title is nothing but an http(s) URL.
  var isLink: Bool

  private static let fileURLType = NSPasteboard.PasteboardType.fileURL.rawValue
  private static let universalClipboardType = NSPasteboard.PasteboardType.universalClipboard.rawValue
  private static let imageTypes = Set(StorageType.images.types.map(\.rawValue))
  // `HistoryItem.universalClipboardText` treats a Universal Clipboard item as
  // text — and therefore ignores its file URL — when it carries any payload of
  // its own. That list is exactly the image and text storage types.
  private static let selfContainedTypes = Set(
    (StorageType.images.types + StorageType.text.types).map(\.rawValue)
  )

  init(_ item: HistoryItem) {
    var types = Set<String>(minimumCapacity: item.contents.count)
    for content in item.contents {
      types.insert(content.type)
    }

    let carriesImageData = !types.isDisjoint(with: Self.imageTypes)
    let universalClipboard = types.contains(Self.universalClipboardType)
    let universalClipboardText = universalClipboard && !types.isDisjoint(with: Self.selfContainedTypes)

    hasFiles = types.contains(Self.fileURLType) && !universalClipboardText

    // A Universal Clipboard image arrives as a `.jpeg` file URL and nothing
    // else; `HistoryItem.imageData` reads the file back for exactly this case.
    let universalClipboardImage = universalClipboard
      && hasFiles
      && !carriesImageData
      && item.fileURLs.first?.pathExtension == "jpeg"

    hasImage = carriesImageData || universalClipboardImage
    isLink = ForkScope.isLink(item.title)
  }
}

/// Per-item classification cache for `ForkScope.matches`.
///
/// Mirrors `Search`'s character-mask cache: keyed by item identity, and
/// validated against the title it was computed from. That is the same signal
/// that invalidates a title elsewhere — text recognition filling in an image's
/// title asynchronously, or `showSpecialSymbols` regenerating every title —
/// which matters because `.links` is decided from the title.
@MainActor
enum ForkItemKindCache {
  private static var entries: [ObjectIdentifier: (title: String, kind: ForkItemKind)] = [:]

  static func kind(of item: HistoryItem) -> ForkItemKind {
    let key = ObjectIdentifier(item)
    let title = item.title

    if let cached = entries[key], cached.title == title {
      return cached.kind
    }

    let kind = ForkItemKind(item)
    entries[key] = (title, kind)
    return kind
  }

  /// Drop the cache once it holds far more than the live item count, so entries
  /// for deleted items cannot accumulate for the life of the process. Called
  /// before a scope filter runs, which is the only thing that fills it.
  static func prune(expecting count: Int) {
    if entries.count > max(count * 2, 256) {
      entries.removeAll(keepingCapacity: true)
    }
  }
}
