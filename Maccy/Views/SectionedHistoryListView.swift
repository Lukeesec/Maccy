import Defaults
import SwiftUI

/// History split into dated sections with small headers, the way system surfaces
/// give a long list rhythm instead of presenting one undifferentiated run of rows.
///
/// Rows keep their position in the underlying array: items are bucketed in list
/// order and the buckets emitted in chronological order, so nothing is reordered
/// when the list is already sorted by date. Grouping is skipped entirely when the
/// user sorts by number of copies, where date sections would be meaningless.
struct SectionedHistoryListView: View {
  var items: [HistoryItemDecorator]

  @Default(.sortBy) private var sortBy

  /// The cheap part: one id and one date per row, which is what decides whether
  /// the previous bucketing still holds. Reading the dates here also keeps the
  /// observation of `lastCopiedAt`/`firstCopiedAt` inside `body`, so a re-copy
  /// still invalidates the view.
  private var stamps: [SectionStamp] {
    items.map { item in
      SectionStamp(
        id: item.id,
        date: sortBy == .firstCopiedAt ? item.item.firstCopiedAt : item.item.lastCopiedAt
      )
    }
  }

  var body: some View {
    let sections = SectionMemo.shared.sections(for: stamps, sortBy: sortBy)

    LazyVStack(spacing: 0) {
      ForEach(sections) { section in
        ForkSectionHeaderView(title: section.kind.title)

        ForEach(section.entries) { entry in
          let previous = entry.index > 0 ? items[entry.index - 1] : nil
          let next = entry.index < items.count - 1 ? items[entry.index + 1] : nil
          HistoryItemView(
            item: items[entry.index],
            previous: previous,
            next: next,
            index: entry.index
          )
        }
      }
    }
  }
}

/// What a row contributes to the section layout.
private struct SectionStamp: Equatable {
  let id: UUID
  let date: Date
}

private struct SectionEntry: Identifiable {
  let index: Int
  let id: UUID
}

private struct HistorySection: Identifiable {
  let kind: ForkTimeSection
  let entries: [SectionEntry]
  var id: String { kind.rawValue }
}

/// Bucketing walks the whole list and asks `Calendar` which day each row falls on.
/// SwiftUI evaluates `body` far more often than the list actually changes -- every
/// hover, every modifier press, every selection move -- so the result is cached
/// and only rebuilt when the rows, their dates, the sort order, or the calendar
/// day itself have moved on.
@MainActor
private final class SectionMemo {
  static let shared = SectionMemo()

  private var cachedStamps: [SectionStamp] = []
  private var cachedSortBy: Sorter.By?
  private var cachedDay: Date = .distantPast
  private var cachedSections: [HistorySection] = []

  func sections(for stamps: [SectionStamp], sortBy: Sorter.By) -> [HistorySection] {
    let now = Date.now

    if sortBy == cachedSortBy,
       Calendar.current.isDate(cachedDay, inSameDayAs: now),
       stamps == cachedStamps {
      return cachedSections
    }

    var buckets: [ForkTimeSection: [SectionEntry]] = [:]
    for (index, stamp) in stamps.enumerated() {
      let kind = ForkTimeSection.containing(stamp.date, now: now)
      buckets[kind, default: []].append(SectionEntry(index: index, id: stamp.id))
    }

    let sections = ForkTimeSection.allCases.compactMap { kind -> HistorySection? in
      guard let entries = buckets[kind], !entries.isEmpty else { return nil }
      return HistorySection(kind: kind, entries: entries)
    }

    cachedStamps = stamps
    cachedSortBy = sortBy
    cachedDay = now
    cachedSections = sections
    return sections
  }
}

struct ForkSectionHeaderView: View {
  let title: String

  var body: some View {
    HStack(spacing: 0) {
      Text(title)
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(.secondary)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, Popup.rowInset + 8)
    .frame(height: Popup.sectionHeaderHeight, alignment: .bottom)
    .padding(.bottom, 3)
    .accessibilityAddTraits(.isHeader)
  }
}
