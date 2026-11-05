import AppKit
import SwiftUI

// Khuluma's look, shared by Stats, Vocabulary and Settings. Text and marks
// are one ink, like the app icon's black line art (black on light, white on
// dark); colour is the ember ramp, amber to red, used for activity, progress
// and selection. See DESIGN.md.

/// One ink, in steps of opacity.
enum Ink {
  static let color = Color.primary
  /// Empty days, tracks and quiet fills.
  static let track = Color.primary.opacity(0.07)
  /// Hairlines between sections and rows.
  static let rule = Color.primary.opacity(0.1)

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

/// Amber to red: the brand colour. Same hues in light and dark.
enum Ember {
  static let amber = Color(red: 0.965, green: 0.706, blue: 0.294)   // #F6B44B
  static let orange = Color(red: 0.949, green: 0.549, blue: 0.220)  // #F28C38
  static let flame = Color(red: 0.918, green: 0.373, blue: 0.165)   // #EA5F2A
  static let red = Color(red: 0.851, green: 0.227, blue: 0.149)     // #D93A26

  /// Heatmap levels 1–4, faint to hot.
  static let levels = [amber, orange, flame, red]
  /// The single accent: selection, focus marks, the active control.
  static let accent = flame

  static let horizontal = LinearGradient(colors: [amber, flame, red], startPoint: .leading, endPoint: .trailing)
  /// Bars: amber at the base, red at the top.
  static let vertical = LinearGradient(colors: [amber, flame], startPoint: .bottom, endPoint: .top)
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
