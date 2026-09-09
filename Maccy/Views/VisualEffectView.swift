import SwiftUI

struct VisualEffectView: NSViewRepresentable {
  let visualEffectView = NSVisualEffectView()

  var material: NSVisualEffectView.Material = .popover
  var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

  func makeNSView(context: Context) -> NSVisualEffectView {
    return visualEffectView
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {
    visualEffectView.material = material
    visualEffectView.blendingMode = blendingMode
  }
}

@available(macOS 26.0, *)
struct GlassEffectView: NSViewRepresentable {
  let glassEffectView = NSGlassEffectView()

  var style: NSGlassEffectView.Style = .regular

  // Appearance-aware tint. Without it the glass takes its cast entirely from the
  // desktop behind the window, so a light wallpaper makes the panel read light
  // even in Dark Mode. windowBackgroundColor is a dynamic system colour and
  // resolves per appearance at draw time.
  var tintColor: NSColor? = NSColor.windowBackgroundColor
    .withAlphaComponent(Popup.glassTintAlpha)

  // Round the glass itself rather than relying on the hosting layer's corner
  // radius, which is set without masking sublayers.
  var cornerRadius: CGFloat = Popup.windowCornerRadius

  func makeNSView(context: Context) -> NSGlassEffectView {
    return glassEffectView
  }

  func updateNSView(_ view: NSGlassEffectView, context: Context) {
    glassEffectView.style = style
    glassEffectView.tintColor = tintColor
    glassEffectView.cornerRadius = cornerRadius
  }
}

#Preview {
  VisualEffectView(
    material: .popover,
    blendingMode: .behindWindow
  )
}
