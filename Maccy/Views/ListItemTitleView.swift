import SwiftUI

struct ListItemTitleView<Title: View>: View {
  var attributedTitle: AttributedString?
  @ViewBuilder var title: () -> Title

  /// Middle truncation reads as a file path convention and mangles content
  /// snippets. System result lists truncate at the end.
  private var truncation: Text.TruncationMode { ForkStyle.isActive ? .tail : .middle }

  var body: some View {
    if let attributedTitle {
      Text(attributedTitle)
        .accessibilityIdentifier("copy-history-item")
        .lineLimit(1)
        .truncationMode(truncation)
    } else {
      title()
        .accessibilityIdentifier("copy-history-item")
        .lineLimit(1)
        .truncationMode(truncation)
        // Workaround for macOS 26 to avoid flipped text
        // https://github.com/p0deje/Maccy/issues/1113
        //
        // This rasterises every row title offscreen and is the most expensive
        // thing in a row, so it was re-examined (2026-09) to see whether it could
        // go. It cannot, on the evidence available:
        //
        //   - upstream master still ships it, unchanged;
        //   - #1113 was only ever closed by this workaround, and #1163, #1214 and
        //     #1219 are the same flipped/mirrored text reported again;
        //   - the underlying fault is in the system's own text rendering, not in
        //     Maccy -- the same inverted-UI bug shows up in Finder dialogs and
        //     menu bar apps on Tahoe -- and there is no Apple release note or
        //     report saying a 26.x update fixed it.
        //
        // Removing it on a guess trades a measurable cost for an unreadable list,
        // so it stays until someone can reproduce the bug being gone.
        .drawingGroup()
    }
  }
}
