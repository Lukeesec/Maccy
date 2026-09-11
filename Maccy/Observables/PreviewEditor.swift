import Foundation
import Observation

/// A scratch buffer for the preview pane.
///
/// The preview is editable, but editing is *not* a way to rewrite history. The
/// draft never touches the stored `HistoryItem`; it only changes what a copy or a
/// paste puts on the pasteboard. That promise is what the "Edited" badge in the
/// pane is advertising, so the invariant matters: nothing here writes back to the
/// model, and the draft is thrown away the moment the selection moves or the popup
/// closes.
@MainActor
@Observable
final class PreviewEditor {
  static let shared = PreviewEditor()

  /// Whether an item can be edited in the preview at all.
  ///
  /// Lives here so the pane and the keyboard cannot drift: focusing an item the
  /// pane will not render as a field leaves `isFocused` stuck true with nothing
  /// on screen, which silently kills Up/Down navigation.
  static func isEditable(_ item: HistoryItemDecorator?) -> Bool {
    guard ForkStyle.isActive, let item else { return false }
    return !item.hasImage && item.item.fileURLs.isEmpty
  }

  /// True when keyboard focus is inside the preview pane.
  ///
  /// Giving this up has to hand the keyboard back explicitly. Nothing else will:
  /// the pane is an `NSTextView`, and resigning it leaves the window itself as
  /// first responder with SwiftUI's `@FocusState` none the wiser, at which point
  /// no key in the popup works at all. Every path that clears the flag -- Escape,
  /// Left arrow, the selection moving, the popup closing -- goes through here, so
  /// this is the one place that has to ask.
  var isFocused: Bool = false {
    didSet {
      guard oldValue, !isFocused else { return }
      AppState.shared.refocusSearch()
    }
  }

  /// True when `draft` differs from the item's original text.
  ///
  /// Maintained by `draft`'s setter rather than computed, so callers can read it
  /// without re-comparing the whole string on every layout pass.
  var isEdited: Bool = false

  /// The scratch text being edited.
  ///
  /// Backed by a separate stored property so the setter can keep `isEdited` in
  /// step. `@Observable` still tracks reads through the getter, so bindings and
  /// `body` invalidation work exactly as they would for a plain stored property.
  var draft: String {
    get { draftStorage }
    set {
      guard newValue != draftStorage else { return }
      draftStorage = newValue
      isEdited = newValue != original
    }
  }

  /// The draft when it has actually been edited, otherwise nil.
  ///
  /// The copy path uses this: nil means "copy the item as stored".
  var effectiveText: String? { isEdited ? draft : nil }

  private var draftStorage: String = ""

  /// The item's text as it was loaded. Not observed: it only ever changes inside
  /// `begin(item:)`, which also writes `draft`, and that write is what should
  /// invalidate views.
  @ObservationIgnored private var original: String = ""

  /// Which item `draft` was loaded from, so that re-rendering the same row does
  /// not throw away an in-flight edit.
  @ObservationIgnored private var itemID: UUID?

  /// Load the item's text into `draft` and clear the edited flag.
  ///
  /// Passing nil resets. Calling it again with the item that is already loaded is
  /// a no-op, so a redraw of the same row keeps the user's edit; calling it with a
  /// different item discards the draft, which is the selection-moved case.
  func begin(item: HistoryItemDecorator?) {
    guard let item else {
      reset()
      return
    }

    guard item.id != itemID else { return }

    itemID = item.id
    original = item.previewText
    draftStorage = original
    isEdited = false
    isFocused = false
  }

  /// Throw the draft away and clear the edited flag.
  func discard() {
    draftStorage = original
    isEdited = false
  }

  private func reset() {
    itemID = nil
    original = ""
    draftStorage = ""
    isEdited = false
    // Clearing focus here is load-bearing: left set with no pane on screen it
    // strands Up/Down navigation.
    isFocused = false
  }
}
