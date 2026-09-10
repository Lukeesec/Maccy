import AppKit
import KeyboardShortcuts
import SwiftUI

struct PreviewItemView: View {
  static var largeTextThreshold = 1_000

  var item: HistoryItemDecorator

  @State private var editor = PreviewEditor.shared

  /// Only plain text is editable. An image has nothing to type into, and a file
  /// item's "text" is a path the pasteboard does not carry as a string.
  private var isEditable: Bool {
    PreviewEditor.isEditable(item)
  }

  @ViewBuilder
  func previewImage(content: () -> some View) -> some View {
    content()
      .aspectRatio(contentMode: .fit)
      .clipShape(.rect(cornerRadius: 5))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      if item.hasImage {
        imagePreview
      } else if isEditable {
        editablePreview
      } else {
        textPreview
      }

      Spacer(minLength: 0)

      Divider()
        .padding(.bottom)

      metadata

      if isEditable {
        keyHints
      }
    }
    .controlSize(.small)
    .padding(ForkStyle.isActive ? 12 : 0)
    // The draft belongs to one row. Rendering a different item is the natural
    // point to throw the previous one away.
    .task(id: item.id) {
      editor.begin(item: isEditable ? item : nil)
    }
    .onDisappear {
      editor.begin(item: nil)
    }
  }

  // MARK: - Body

  @ViewBuilder
  private var imagePreview: some View {
    AsyncView<NSImage?, _, _>(id: item.id) {
      return await item.asyncGetPreviewImage()
    } content: { image in
      if let image = image {
        previewImage {
          Image(nsImage: image)
            .resizable()
        }
      } else {
        previewImage {
          ZStack {
            Color.gray.opacity(0.3)
              .frame(
                idealWidth: HistoryItemDecorator.previewImageSize.width,
                idealHeight: HistoryItemDecorator.previewImageSize.height
              )
            Image(systemName: "photo.badge.exclamationmark")
              .symbolRenderingMode(.multicolor)
              .frame(alignment: .center)
          }
        }
      }
    } placeholder: {
      previewImage {
        ZStack {
          Color.gray.opacity(0.3)
            .frame(
              idealWidth: HistoryItemDecorator.previewImageSize.width,
              idealHeight: HistoryItemDecorator.previewImageSize.height
            )
          ProgressView()
            .frame(alignment: .center)
        }
      }
    }
  }

  /// Upstream's read-only preview. Still used for files, and on anything before
  /// macOS 26.
  @ViewBuilder
  private var textPreview: some View {
    let text = item.previewText
    if text.count >= Self.largeTextThreshold {
      LargeTextPreviewView(text: text)
        .id("textpreview-\(item.id)")
    } else {
      ScrollView {
        Text(text)
          .font(.body)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .frame(maxWidth: .infinity)
    }
  }

  /// The editable pane. It reads as a field only while it has focus; unfocused it
  /// stays as quiet as the read-only preview it replaces.
  @ViewBuilder
  private var editablePreview: some View {
    VStack(alignment: .leading, spacing: 6) {
      if editor.isEdited {
        editedBadge
      }

      EditablePreviewTextView(
        text: Binding(get: { editor.draft }, set: { editor.draft = $0 }),
        isFocused: Binding(get: { editor.isFocused }, set: { editor.isFocused = $0 }),
        content: editor.draft,
        focused: editor.isFocused
      )
      .frame(maxWidth: .infinity, minHeight: 44)
      .padding(6)
      .background(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.accentColor.opacity(editor.isFocused ? 0.06 : 0))
      )
      .overlay(
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(
            editor.isFocused ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.08),
            lineWidth: 1
          )
      )
      .animation(.easeOut(duration: 0.12), value: editor.isFocused)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  /// The visible promise that history was not rewritten: what is on screen is a
  /// scratch copy, and only the copy is affected.
  private var editedBadge: some View {
    HStack(spacing: 4) {
      Image(systemName: "pencil")
        .font(.system(size: 9, weight: .semibold))
      Text(LocalizedStringKey("preview_edited_badge"))
        .font(.system(size: 10, weight: .semibold).smallCaps())
    }
    .foregroundStyle(Color(nsColor: .systemOrange))
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(Color(nsColor: .systemYellow).opacity(0.18), in: Capsule())
    .accessibilityElement(children: .combine)
  }

  // MARK: - Metadata

  @ViewBuilder
  private var metadata: some View {
    if ForkStyle.isActive {
      metadataRows
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        // The rows are label/value HStacks; without this they wrap mid-word
        // ("Septemb / er 9") once the padding narrows the column.
        .lineLimit(1)
    } else {
      metadataRows
    }
  }

  @ViewBuilder
  private var metadataRows: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let application = item.application {
        HStack(spacing: 3) {
          Text("Application", tableName: "PreviewItemView")
          AppImageView(
            appImage: item.applicationImage,
            size: NSSize(width: 11, height: 11)
          )
          Text(application)
        }
      }

      if item.hasImage, let image = item.item.image {
        HStack(spacing: 3) {
          Text("Dimensions", tableName: "PreviewItemView")
          Text("\(Int(image.pixelSize.width))×\(Int(image.pixelSize.height))")
        }
      }

      HStack(spacing: 3) {
        Text("FirstCopyTime", tableName: "PreviewItemView")
        Text(item.item.firstCopiedAt, style: .date)
        Text(item.item.firstCopiedAt, style: .time)
      }

      HStack(spacing: 3) {
        Text("LastCopyTime", tableName: "PreviewItemView")
        Text(item.item.lastCopiedAt, style: .date)
        Text(item.item.lastCopiedAt, style: .time)
      }

      HStack(spacing: 3) {
        Text("NumberOfCopies", tableName: "PreviewItemView")
        Text(String(item.item.numberOfCopies))
      }
    }
  }

  // MARK: - Key hints

  private var keyHints: some View {
    HStack(spacing: 14) {
      hint("↩", "preview_copy_edited")
      hint("⌥↩", "preview_paste_edited")
      Spacer(minLength: 0)
    }
    .padding(.top, 8)
  }

  private func hint(_ keys: String, _ labelKey: String) -> some View {
    HStack(spacing: 4) {
      Text(verbatim: keys)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
      Text(LocalizedStringKey(labelKey))
        .font(.system(size: 11))
        .foregroundStyle(.tertiary)
    }
  }
}

/// The editable body of the preview.
///
/// `TextEditor` would be less code, but it owns its key handling: Return would
/// insert a newline instead of copying, and Escape would not reach the popup. An
/// `NSTextView` lets those keys fall through to the responder chain, and it is
/// also the only path that stays responsive on a very large clipping — which is
/// why the read-only preview already uses one.
struct EditablePreviewTextView: NSViewRepresentable {
  @Binding var text: String
  @Binding var isFocused: Bool
  /// The same value as `text`, passed as a plain read, for the reason below.
  let content: String
  /// The same value as `isFocused`, passed as a plain read.
  ///
  /// Constructing `Binding(get:set:)` never calls the getter during body
  /// evaluation, so @Observable registers no dependency on `isFocused` and the
  /// parent is never invalidated when it changes -- which meant `updateNSView`
  /// never ran and focus was never applied. Reading the value at the call site
  /// is what establishes the dependency; `updateNSView` then uses this rather
  /// than the binding.
  let focused: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator(text: $text, isFocused: $isFocused)
  }

  func makeNSView(context: Context) -> NSScrollView {
    let textView = PreviewTextView(usingTextLayoutManager: true)
    LargeTextPreviewView.configure(textView: textView, text: text)
    textView.isEditable = true
    textView.isSelectable = true
    textView.allowsUndo = true
    textView.delegate = context.coordinator
    textView.onFocusChange = { [weak coordinator = context.coordinator] focused in
      coordinator?.reportFocus(focused)
    }

    return LargeTextPreviewView.makeScrollView(documentView: textView)
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? PreviewTextView else { return }

    if textView.string != content {
      textView.string = content
      // Assigning .string resets the selection, and it can land after the
      // becomeFirstResponder caret placement. Re-assert the caret here so the
      // first keystroke extends the draft instead of replacing it.
      textView.setSelectedRange(NSRange(location: (content as NSString).length, length: 0))
    }

    context.coordinator.syncFirstResponder(to: focused, in: textView)
  }

  @MainActor
  final class Coordinator: NSObject, NSTextViewDelegate {
    @Binding private var text: String
    @Binding private var isFocused: Bool

    private var isSyncingFocus = false

    init(text: Binding<String>, isFocused: Binding<Bool>) {
      _text = text
      _isFocused = isFocused
    }

    func textDidChange(_ notification: Notification) {
      guard let textView = notification.object as? NSTextView else { return }
      guard text != textView.string else { return }
      text = textView.string
    }

    func reportFocus(_ focused: Bool) {
      guard !isSyncingFocus, isFocused != focused else { return }
      isFocused = focused
    }

    /// Focus moves both ways. The original contract here was that whatever
    /// cleared the flag would also focus something else, and that this view would
    /// resign as a side effect — but no caller did, so clearing the flag left the
    /// text view still first responder while the pane redrew itself unfocused,
    /// and every later keystroke kept landing in the draft. Resigning explicitly
    /// hands the window back to SwiftUI, whose @FocusState then reasserts the
    /// search field.
    func syncFirstResponder(to focused: Bool, in textView: PreviewTextView) {
      guard !isSyncingFocus, let window = textView.window else { return }

      if !focused {
        // NSTextView is its own field editor, so it is the first responder
        // directly -- there is no currentEditor() indirection here.
        guard window.firstResponder === textView else { return }
        isSyncingFocus = true
        DispatchQueue.main.async { [weak self, weak textView] in
          defer { self?.isSyncingFocus = false }
          guard let textView, let window = textView.window else { return }
          guard window.firstResponder === textView else { return }
          window.makeFirstResponder(nil)
        }
        return
      }

      guard window.firstResponder !== textView else { return }

      isSyncingFocus = true
      // Out of the current update pass: changing first responder underneath
      // SwiftUI's own focus machinery mid-layout is asking for a fight.
      DispatchQueue.main.async { [weak self, weak textView] in
        defer { self?.isSyncingFocus = false }
        guard let textView, let window = textView.window else { return }
        guard window.firstResponder !== textView else { return }
        window.makeFirstResponder(textView)
      }
    }
  }
}

/// An `NSTextView` that reports first-responder changes and refuses to swallow the
/// popup's own keys. Return copies, Escape closes, Tab moves focus — none of them
/// belong to the field. Shift-Return is left alone so a newline is still typable.
final class PreviewTextView: NSTextView {
  var onFocusChange: (@MainActor (Bool) -> Void)?

  private static let passthroughKeyCodes: Set<UInt16> = [
    36,  // Return
    76,  // Enter (keypad)
    48,  // Tab
    53,  // Escape
    123  // Left arrow — the documented way back out to the list
  ]

  override func becomeFirstResponder() -> Bool {
    let accepted = super.becomeFirstResponder()
    if accepted {
      // NSTextView selects its whole contents when it takes first responder, so
      // the first keystroke would replace the draft rather than extend it.
      // AppKit installs that selection after this returns, and after the string
      // assignment in updateNSView, so both earlier attempts were overwritten --
      // the caret has to be placed a runloop turn later to survive.
      // The identity of window.firstResponder is not reliably `self` here (AppKit
      // may route through a field editor), so this deliberately does not guard on
      // it -- guarding was why the two earlier attempts silently did nothing.
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.setSelectedRange(NSRange(location: (self.string as NSString).length, length: 0))
      }
      onFocusChange?(true)
    }
    return accepted
  }

  override func resignFirstResponder() -> Bool {
    let resigned = super.resignFirstResponder()
    if resigned { onFocusChange?(false) }
    return resigned
  }

  override func keyDown(with event: NSEvent) {
    let isReturn = event.keyCode == 36 || event.keyCode == 76
    // Shift-Return is the one way to type a newline into the draft.
    if isReturn, event.modifierFlags.contains(.shift) {
      super.keyDown(with: event)
      return
    }

    // Anything carrying a command-ish modifier belongs to the popup, not to the
    // field. Listing key codes was not enough: ⌃C and ⌥C are the fork's copy
    // shortcuts, and left to NSTextView the first is swallowed and the second
    // inserts a "ç". This is the same trap KeyChord guards against one layer up.
    let commandish = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .intersection([.command, .control, .option])
    if !commandish.isEmpty {
      nextResponder?.keyDown(with: event)
      return
    }

    if Self.passthroughKeyCodes.contains(event.keyCode) {
      nextResponder?.keyDown(with: event)
      return
    }

    super.keyDown(with: event)
  }
}

struct LargeTextPreviewView: NSViewRepresentable {
  let text: String

  func makeNSView(context: Context) -> NSScrollView {
    return Self.makeScrollView(text: text)
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = scrollView.documentView as? NSTextView, textView.string != text else {
      return
    }

    textView.string = text
  }

  static func makeScrollView(text: String) -> NSScrollView {
    let textView = NSTextView(usingTextLayoutManager: true)
    configure(textView: textView, text: text)
    return makeScrollView(documentView: textView)
  }

  static func configure(textView: NSTextView, text: String) {
    textView.isEditable = false
    textView.isSelectable = false
    textView.isRichText = false
    textView.drawsBackground = false
    textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
    textView.textColor = .labelColor
    textView.textContainerInset = .zero
    textView.minSize = .zero
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude,
      height: CGFloat.greatestFiniteMagnitude
    )
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false
    textView.autoresizingMask = [.width]
    textView.textContainer?.lineFragmentPadding = 0
    textView.textContainer?.widthTracksTextView = true
    textView.textContainer?.heightTracksTextView = false
    textView.string = text
  }

  static func makeScrollView(documentView: NSTextView) -> NSScrollView {
    let scrollView = NSScrollView()
    scrollView.documentView = documentView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.borderType = .noBorder
    scrollView.drawsBackground = false
    return scrollView
  }
}
