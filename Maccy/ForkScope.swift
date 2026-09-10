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
  func matches(_ item: HistoryItem) -> Bool {
    switch self {
    case .all:
      return true
    case .images:
      return item.image != nil
    case .files:
      return !item.fileURLs.isEmpty
    case .links:
      return Self.isLink(item.title)
    case .text:
      return item.image == nil && item.fileURLs.isEmpty
    }
  }

  /// A title is treated as a link when it is nothing but an http(s) URL.
  /// Anything with whitespace in it is prose that happens to start with a URL.
  private static func isLink(_ title: String) -> Bool {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") else {
      return false
    }

    return !trimmed.contains(where: \.isWhitespace)
  }
}
