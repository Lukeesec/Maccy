import Defaults
import Foundation

// Runtime-switchable presentation variants for the Spotlight redesign.
//
// These exist so the contentious parts of the redesign can be compared on a real
// machine without a rebuild, and the losers deleted afterwards. Flip one with
// script/set-style.sh, for example:
//
//   script/set-style.sh rowStyle oneLine
//   script/set-style.sh chrome stripped
//   script/set-style.sh selectionStyle neutralPill
//
// `defaults write org.p0deje.Maccy <key>` does NOT work here. macOS still has a
// sandbox container registered for the bundle identifier and redirects domain
// writes into it, while the unsandboxed fork reads
// ~/Library/Preferences/org.p0deje.Maccy.plist. The write appears to succeed and
// `defaults read` even reflects it, but the app never sees it. The script writes
// to that path directly.
//
// Every variant is gated to macOS 26; older systems keep upstream's layout,
// which is tuned for NSVisualEffectView.

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

/// Where the actions affordance lives, and therefore how it is reached.
///
/// The per-row variant was removed: a circular button on every selected row read
/// as clutter rather than as an affordance. Right arrow, which used to reach it,
/// now opens the preview.
///
/// Arrowing up out of the list into a toolbar glyph is not a macOS idiom --
/// nothing in the system navigates from a list into its own chrome that way.
/// These all use Tab, which is what macOS uses to move focus between controls,
/// plus Right arrow when the search field is empty.
enum ForkActions: String, CaseIterable, Identifiable, Defaults.Serializable {
  /// One glyph at the trailing edge of the search row. Tab reaches it.
  case searchRow
  /// One glyph at the right of the bottom hint bar, keeping the search row clean.
  case hintBar
  /// No affordance at all, which is what Spotlight itself does: its settings live
  /// in System Settings, not in the panel. Cmd+, still works.
  case none

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
  /// Every variant, resolved once at first use.
  ///
  /// These are read several times per row per layout pass -- row height, icon
  /// size, insets, selection shape -- and each read used to reach into
  /// UserDefaults. Nothing here can change inside a running process: the
  /// switcher script writes the plist and then quits and relaunches Maccy, which
  /// is the only supported way to change a variant. So resolve the whole set on
  /// first touch and hand out the cached values afterwards.
  private struct Resolved {
    let isActive: Bool
    let rowStyle: ForkRowStyle
    let chrome: ForkChrome
    let selectionStyle: ForkSelectionStyle
    let grouping: ForkGrouping
    let actions: ForkActions

    init() {
      let active: Bool
      if #available(macOS 26.0, *) { active = true } else { active = false }

      isActive = active
      rowStyle = active ? Defaults[.forkRowStyle] : .compact
      chrome = active ? Defaults[.forkChrome] : .menu
      selectionStyle = active ? Defaults[.forkSelectionStyle] : .bar
      grouping = active ? Defaults[.forkGrouping] : ForkGrouping.none
      actions = active ? Defaults[.forkActions] : ForkActions.none
    }
  }

  /// `static let` is lazy and initialised exactly once, so this is the cache.
  private static let resolved = Resolved()

  /// The redesign only applies on macOS 26. Everything below falls back to upstream.
  static var isActive: Bool { resolved.isActive }

  static var rowStyle: ForkRowStyle { resolved.rowStyle }
  static var chrome: ForkChrome { resolved.chrome }
  static var selectionStyle: ForkSelectionStyle { resolved.selectionStyle }
  static var grouping: ForkGrouping { resolved.grouping }
  static var actions: ForkActions { resolved.actions }
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
