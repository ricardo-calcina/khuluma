import AppKit
import SwiftUI
import KhulumaCore

// Khuluma's look, shared by Stats, Vocabulary and Settings. Text and marks
// are one ink, like the app icon's black line art (black on light, white on
// dark); colour is the ember ramp, amber to red, used for activity, progress
// and selection. See DESIGN.md.

/// The light-mode palette. Dark mode has one look; light mode is chosen by
/// the preview-only `KhulumaLightPalette` key while a direction is picked.
enum LightPalette: String {
  case system, ivory, white, glow

  static let current: LightPalette = {
    let key = "KhulumaLightPalette"
    let value = AppRuntimePaths.defaults.string(forKey: key) ?? UserDefaults.standard.string(forKey: key)
    return value.flatMap(LightPalette.init(rawValue:)) ?? .ivory
  }()
}

/// A colour with a light and a dark value, resolved by the view's appearance.
private func dynamic(_ name: String, light: @escaping () -> NSColor, dark: @escaping () -> NSColor) -> NSColor {
  NSColor(name: NSColor.Name("Khuluma.\(name)")) { appearance in
    appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark() : light()
  }
}

private func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
  NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
          blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

/// The label colour at an opacity, as `Color.primary.opacity` draws it.
private func ink(_ opacity: CGFloat) -> NSColor {
  NSColor(name: nil) { appearance in
    var color = NSColor.labelColor
    appearance.performAsCurrentDrawingAppearance {
      color = NSColor.labelColor.usingColorSpace(.sRGB) ?? .labelColor
    }
    return color.withAlphaComponent(color.alphaComponent * opacity)
  }
}

/// Window and page backgrounds.
enum Surface {
  static let canvasColor = dynamic("canvas", light: {
    switch LightPalette.current {
    case .system: return .windowBackgroundColor
    case .ivory: return hex(0xFCF9F3)
    case .white: return hex(0xFFFFFF)
    case .glow: return hex(0xFFF9F0)
    }
  }, dark: { .windowBackgroundColor })
  static let canvas = Color(nsColor: canvasColor)
}

/// One ink, in steps of opacity.
enum Ink {
  static let color = Color.primary
  /// Empty days, tracks and quiet fills.
  static let track = Color(nsColor: dynamic("track", light: {
    switch LightPalette.current {
    case .system: return ink(0.07)
    case .ivory: return hex(0xEDE7DE)
    case .white: return hex(0xEFEDEB)
    case .glow: return hex(0xF9E6D1)
    }
  }, dark: { ink(0.07) }))
  /// Hairlines between sections and rows.
  static let rule = Color(nsColor: dynamic("rule", light: {
    switch LightPalette.current {
    case .system: return ink(0.1)
    case .ivory: return hex(0xE5DFD6)
    case .white: return hex(0xE5E2E0)
    case .glow: return hex(0xEDDACA)
    }
  }, dark: { ink(0.1) }))

  /// A small caps label: under a figure, or heading a group of rows.
  static func label(_ text: String) -> some View {
    Text(text.uppercased())
      .font(.system(size: 10, weight: .medium))
      .tracking(0.8)
      .foregroundStyle(.secondary)
      .lineLimit(1)
      .minimumScaleFactor(0.8)
  }
}

/// Amber to red: the brand colour. On a light canvas the ramp is re-tuned
/// (OKLCH L 0.775 → 0.56) so every step keeps contrast.
enum Ember {
  private static func ramp(_ name: String, _ today: UInt32, light: UInt32) -> Color {
    Color(nsColor: dynamic(name, light: { hex(LightPalette.current == .system ? today : light) },
                           dark: { hex(today) }))
  }
  static let amber = ramp("amber", 0xF6B44B, light: 0xF0A432)
  static let orange = ramp("orange", 0xF28C38, light: 0xEC7F1F)
  static let flame = ramp("flame", 0xEA5F2A, light: 0xE3581E)
  static let red = ramp("red", 0xD93A26, light: 0xCC3622)

  /// Heatmap levels 1–4, faint to hot.
  static let levels = [amber, orange, flame, red]
  /// The single accent: selection, focus marks, the active control.
  static let accent = flame
  /// Text in the accent colour: 4.5:1 on a light canvas.
  static let accentText = Color(nsColor: dynamic("accentText", light: {
    LightPalette.current == .system ? hex(0xEA5F2A) : hex(0xB8401A)
  }, dark: { hex(0xEA5F2A) }))
  /// The selected row or segment's fill.
  static let selection = Color(nsColor: dynamic("selection", light: {
    hex(LightPalette.current == .system ? 0xEA5F2A : 0xE3581E, alpha: 0.14)
  }, dark: { hex(0xEA5F2A, alpha: 0.22) }))

  static let horizontal = LinearGradient(colors: [amber, flame, red], startPoint: .leading, endPoint: .trailing)
  /// Bars: amber to flame on dark; orange to red on a light canvas, where
  /// amber reads washed out.
  static let vertical = LinearGradient(colors: [
    Color(nsColor: dynamic("barBase", light: { hex(LightPalette.current == .system ? 0xF6B44B : 0xEC7F1F) },
                           dark: { hex(0xF6B44B) })),
    Color(nsColor: dynamic("barTop", light: { hex(LightPalette.current == .system ? 0xEA5F2A : 0xCC3622) },
                           dark: { hex(0xEA5F2A) })),
  ], startPoint: .bottom, endPoint: .top)
}

/// A bar's opacity: full when highlighted, else 0.8 (0.9 on a light canvas).
struct BarOpacity: ViewModifier {
  let highlighted: Bool
  @Environment(\.colorScheme) private var scheme

  func body(content: Content) -> some View {
    let resting = scheme == .light && LightPalette.current != .system ? 0.9 : 0.8
    return content.opacity(highlighted ? 1 : resting)
  }
}

/// Heatmap cell colours.
enum HeatColor {
  static let empty = Ink.track

  static func fill(_ level: Int) -> Color {
    Ember.levels[min(max(level, 1), Ember.levels.count) - 1]
  }
}

/// Khuluma's own mark: a symbol inside an ink ring, like the eyes in the
/// app icon. Monochrome, so it follows light and dark mode.
struct RingMark: View {
  let symbol: String
  var size: CGFloat = 24
  var tint: Color = Ink.color.opacity(0.85)

  var body: some View {
    Circle()
      .strokeBorder(tint, lineWidth: 1.6)
      .frame(width: size, height: size)
      .overlay {
        Image(systemName: symbol)
          .font(.system(size: size * 0.42, weight: .semibold))
          .foregroundStyle(tint)
      }
      .accessibilityHidden(true)
  }
}

/// A faint full-width hairline.
struct Rule: View {
  var body: some View {
    Rectangle().fill(Ink.rule).frame(height: 1)
  }
}

/// Hover state without @State: the Command Line Tools have no SwiftUI macro plugin.
final class HoverState: ObservableObject {
  @Published var active = false
}

/// A small switch drawn in SwiftUI. AppKit draws its switch as inactive (grey)
/// in a menu window, which isn't key, so `.tint` has no effect there.
struct KhulumaSwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    SwitchBody(configuration: configuration)
  }

  private struct SwitchBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var hover = HoverState()

    var body: some View {
      Button { configuration.isOn.toggle() } label: {
        HStack(spacing: 6) {
          configuration.label
          ZStack(alignment: configuration.isOn ? .trailing : .leading) {
            Capsule()
              .fill(configuration.isOn ? Ember.accent : Ink.track)
              .overlay(Capsule().fill(Ink.color.opacity(hover.active && isEnabled ? 0.06 : 0)))
              .overlay(Capsule().strokeBorder(Ink.color.opacity(configuration.isOn ? 0 : 0.12), lineWidth: 0.5))
            Circle()
              .fill(.white)
              .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
              .padding(1.5)
          }
          .frame(width: 26, height: 15)
          .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isOn)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .onHover { hover.active = $0 }
      .opacity(isEnabled ? 1 : 0.45)
      .accessibilityElement(children: .combine)
      .accessibilityAddTraits(.isToggle)
      .accessibilityValue(configuration.isOn ? "On" : "Off")
    }
  }
}

/// A segmented control in Khuluma's look: capsule segments on an ink track,
/// the selected one tinted ember like the Settings sidebar's selected row.
struct KhulumaSegments<Option: Hashable>: View {
  enum Size {
    case small, regular
    var font: Font { self == .small ? .callout : .system(size: 13) }
    var height: CGFloat { self == .small ? 22 : 26 }
  }

  let label: String
  let options: [(value: Option, title: String)]
  @Binding var selection: Option
  var size: Size = .regular

  @Namespace private var pill
  @FocusState private var focused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  /// Equal widths: the widest title plus 12 pt either side.
  private var segmentWidth: CGFloat {
    let font = NSFont.systemFont(ofSize: size == .small ? NSFont.preferredFont(forTextStyle: .callout).pointSize : 13,
                                 weight: .semibold)
    let widest = options.map { ($0.title as NSString).size(withAttributes: [.font: font]).width }.max() ?? 0
    return (widest + 24).rounded(.up)
  }

  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.value) { option in
        Segment(title: option.title, selected: option.value == selection, size: size,
                width: segmentWidth, pill: pill) { select(option.value) }
      }
    }
    .padding(2)
    .frame(height: size.height)
    .background(Capsule().fill(Ink.track))
    .overlay(Capsule().strokeBorder(Ink.rule, lineWidth: 0.5))
    .overlay(Capsule().strokeBorder(Ember.accent, lineWidth: focused ? 2 : 0))
    .fixedSize()
    .focusable()
    .focusEffectDisabled()
    .focused($focused)
    .onMoveCommand { direction in
      switch direction {
      case .left: step(-1)
      case .right: step(1)
      default: break
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label)
  }

  private func step(_ offset: Int) {
    guard let index = options.firstIndex(where: { $0.value == selection }) else { return }
    let next = index + offset
    if options.indices.contains(next) { select(options[next].value) }
  }

  private func select(_ value: Option) {
    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { selection = value }
  }

  private struct Segment: View {
    let title: String
    let selected: Bool
    let size: Size
    let width: CGFloat
    let pill: Namespace.ID
    let action: () -> Void
    @StateObject private var hover = HoverState()

    var body: some View {
      Button(action: action) {
        Text(title)
          .font(size.font)
          .fontWeight(selected ? .semibold : .regular)
          .foregroundStyle(selected ? Ember.accentText : hover.active ? Color.primary : Color.secondary)
          .lineLimit(1)
          .frame(width: width)
          .frame(maxHeight: .infinity)
          .contentShape(Capsule())
      }
      .buttonStyle(SegmentButtonStyle(selected: selected, hovering: hover.active, pill: pill))
      .onHover { hover.active = $0 }
      .accessibilityLabel(title)
      .accessibilityAddTraits(selected ? .isSelected : [])
    }
  }

  private struct SegmentButtonStyle: ButtonStyle {
    let selected: Bool
    let hovering: Bool
    let pill: Namespace.ID

    func makeBody(configuration: Configuration) -> some View {
      configuration.label
        .background {
          if selected {
            Capsule().fill(Ember.selection).matchedGeometryEffect(id: "pill", in: pill)
          } else if configuration.isPressed || hovering {
            Capsule().fill(Ink.color.opacity(configuration.isPressed ? 0.10 : 0.06))
          }
        }
    }
  }
}
