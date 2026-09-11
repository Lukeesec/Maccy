import Defaults
import SwiftUI

struct HistoryItemView: View {
  @Bindable var item: HistoryItemDecorator
  var previous: HistoryItemDecorator?
  var next: HistoryItemDecorator?
  var index: Int

  private var selectionAppearance: SelectionAppearance {
    let previousSelected = previous?.isSelected ?? false
    let nextSelected = next?.isSelected ?? false
    switch (previousSelected, nextSelected) {
    case (true, false):
      return .topConnection
    case (false, true):
      return .bottomConnection
    case (true, true):
      return .topBottomConnection
    default:
      return .none
    }
  }

  @Default(.showHexColorSwatch) private var showHexColorSwatch
  @Environment(AppState.self) private var appState

  private var colorSwatchImage: NSImage? {
    guard showHexColorSwatch else { return nil }
    return ColorImage.from(item.title)
  }

  private static let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .none
    formatter.timeStyle = .short
    return formatter
  }()

  /// Short label for anything that is not plain text. Text is the overwhelming
  /// majority, and Spotlight does not label the obvious case.
  private var kindLabel: String? {
    if item.hasImage {
      return NSLocalizedString("kind_image", comment: "")
    }
    if !item.item.fileURLs.isEmpty {
      return NSLocalizedString("kind_file", comment: "")
    }
    let trimmed = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"),
       !trimmed.contains(" ") {
      return NSLocalizedString("kind_link", comment: "")
    }
    return nil
  }

  /// Secondary line: where it came from, when, and what kind it is.
  private var subtitle: String? {
    guard ForkStyle.rowStyle == .twoLine else { return nil }

    var parts: [String] = []
    if let application = item.application {
      parts.append(application)
    }
    parts.append(Self.timeFormatter.string(from: item.item.lastCopiedAt))
    if let kindLabel {
      parts.append(kindLabel)
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  private func performSelect() {
    if NSEvent.modifierFlags.contains(.command) && appState.multiSelectionEnabled {
      appState.navigator.addToSelection(item: item)
    } else {
      let flags = NSEvent.ModifierFlags.currentModifierFlags
      Task {
        appState.history.select(item, flags: flags)
      }
    }
  }

  private var plainTextActionPresented: Binding<Bool> {
    Binding(
      get: {
        appState.plainTextActionItemID == item.id && item.isSelected
      },
      set: { isPresented in
        if !isPresented, appState.plainTextActionItemID == item.id {
          appState.dismissPlainTextAction()
        }
      }
    )
  }

  var body: some View {
    ListItemView(
      id: item.id,
      selectionId: item.id,
      appIcon: item.applicationImage,
      image: item.thumbnailImage,
      accessoryImage: item.thumbnailImage != nil ? nil : colorSwatchImage,
      attributedTitle: item.attributedTitle,
      subtitle: subtitle,
      shortcuts: item.shortcuts,
      isSelected: item.isSelected,
      selectionIndex: item.multiSelectionIndex,
      selectionAppearance: selectionAppearance,
      accessibilityLabel: item.accessibilityLabel
    ) {
      Text(verbatim: item.title)
    }
    .accessibilityIdentifier("copy-history-item")
    .buttonAction(performSelect)
    .popover(isPresented: plainTextActionPresented, arrowEdge: .leading) {
      PlainTextActionView(item: item)
    }
    .onAppear {
      item.ensureThumbnailImage()
    }
    .accessibilityAction(named: Text(item.isPinned ? "history_item_unpin_action" : "history_item_pin_action")) {
      appState.history.togglePin(item)
    }
    .accessibilityAction(named: Text("history_item_delete_action")) {
      appState.history.delete(item)
    }
  }
}

/// A deliberately small, one-shot menu for the selected history row. It is
/// opened with Left after keyboard navigation enters the list; Return invokes
/// it, while clicking the button provides the same discoverable path.
private struct PlainTextActionView: View {
  let item: HistoryItemDecorator

  @Environment(AppState.self) private var appState

  var body: some View {
    Button {
      appState.paste(item, removeFormatting: true)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: "textformat")
          .foregroundStyle(.secondary)
          .frame(width: 16)

        Text("paste_without_formatting_action")

        Spacer(minLength: 12)

        Text("↩")
          .foregroundStyle(.secondary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .keyboardShortcut(.return, modifiers: [])
    .accessibilityHint(Text("paste_without_formatting_hint"))
    .padding(10)
    .frame(width: 230)
  }
}
