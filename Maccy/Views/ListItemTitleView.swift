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
        .drawingGroup()
    }
  }
}
