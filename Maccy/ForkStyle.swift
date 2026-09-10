import Defaults
import Foundation

// Runtime-switchable presentation variants for the Spotlight redesign.
//
// These exist so the contentious parts of the redesign can be compared on a real
// machine without a rebuild, and the losers deleted afterwards. Flip one with:
//
//   defaults write org.p0deje.Maccy forkRowStyle twoLine
//   defaults write org.p0deje.Maccy forkChrome hintBar
//   defaults write org.p0deje.Maccy forkSelectionStyle pill
//
// then reopen the popup. Every variant is gated to macOS 26; older systems keep
// upstream's layout, which is tuned for NSVisualEffectView.

/// How much vertical structure each history row carries.
enum ForkRowStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
  /// Content line plus a secondary line of source app and time.
  case twoLine
  /// Single content line, Spotlight spacing and icon treatment.
  case oneLine
  /// Upstream's compact row.
  case compact

  var id: Self { self }
}

/// What survives of the app's own chrome: the footer menu and the header title.
enum ForkChrome: String, CaseIterable, Identifiable, Defaults.Serializable {
  /// Nothing. Actions live behind the header's overflow button and ⌘,.
  case stripped
  /// A quiet bottom bar of keyboard hints, no selectable menu rows.
  case hintBar
  /// Upstream's Clear / Preferences / About / Quit list.
  case menu

  var id: Self { self }
}

/// How the highlighted row is drawn.
enum ForkSelectionStyle: String, CaseIterable, Identifiable, Defaults.Serializable {
  /// Inset rounded pill with margin from the panel edge, label left in its own colour.
  case pill
  /// Inset pill using a neutral fill rather than an accent tint.
  case neutralPill
  /// Upstream's full-bleed accent bar with a white label.
  case bar

  var id: Self { self }
}

/// Whether rows are broken into dated sections.
enum ForkGrouping: String, CaseIterable, Identifiable, Defaults.Serializable {
  /// Today / Yesterday / This Week / Earlier headers.
  case byTime
  /// One flat list.
  case none

  var id: Self { self }
}

enum ForkStyle {
  /// The redesign only applies on macOS 26. Everything below falls back to upstream.
  static var isActive: Bool {
    if #available(macOS 26.0, *) { return true } else { return false }
  }

  static var rowStyle: ForkRowStyle { isActive ? Defaults[.forkRowStyle] : .compact }
  static var chrome: ForkChrome { isActive ? Defaults[.forkChrome] : .menu }
  static var selectionStyle: ForkSelectionStyle { isActive ? Defaults[.forkSelectionStyle] : .bar }
  static var grouping: ForkGrouping { isActive ? Defaults[.forkGrouping] : .none }
}

/// Section a history item falls into when grouping by time.
enum ForkTimeSection: String, CaseIterable, Identifiable {
  case today
  case yesterday
  case thisWeek
  case earlier

  var id: Self { self }

  static func containing(_ date: Date, now: Date = .now) -> ForkTimeSection {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return .today }
    if calendar.isDateInYesterday(date) { return .yesterday }
    if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now), date >= weekAgo {
      return .thisWeek
    }
    return .earlier
  }

  var title: String {
    switch self {
    case .today: return NSLocalizedString("Today", tableName: "ForkStyle", comment: "")
    case .yesterday: return NSLocalizedString("Yesterday", tableName: "ForkStyle", comment: "")
    case .thisWeek: return NSLocalizedString("This Week", tableName: "ForkStyle", comment: "")
    case .earlier: return NSLocalizedString("Earlier", tableName: "ForkStyle", comment: "")
    }
  }
}
