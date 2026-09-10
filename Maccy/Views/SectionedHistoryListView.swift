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

  private struct Section: Identifiable {
    let kind: ForkTimeSection
    let entries: [Entry]
    var id: String { kind.rawValue }
  }

  private struct Entry: Identifiable {
    let index: Int
    let item: HistoryItemDecorator
    var id: UUID { item.id }
  }

  private func date(of item: HistoryItemDecorator) -> Date {
    sortBy == .firstCopiedAt ? item.item.firstCopiedAt : item.item.lastCopiedAt
  }

  private var sections: [Section] {
    var buckets: [ForkTimeSection: [Entry]] = [:]
    for (index, item) in items.enumerated() {
      let kind = ForkTimeSection.containing(date(of: item))
      buckets[kind, default: []].append(Entry(index: index, item: item))
    }

    return ForkTimeSection.allCases.compactMap { kind in
      guard let entries = buckets[kind], !entries.isEmpty else { return nil }
      return Section(kind: kind, entries: entries)
    }
  }

  var body: some View {
    LazyVStack(spacing: 0) {
      ForEach(sections) { section in
        ForkSectionHeaderView(title: section.kind.title)

        ForEach(section.entries) { entry in
          let previous = entry.index > 0 ? items[entry.index - 1] : nil
          let next = entry.index < items.count - 1 ? items[entry.index + 1] : nil
          HistoryItemView(
            item: entry.item,
            previous: previous,
            next: next,
            index: entry.index
          )
        }
      }
    }
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
