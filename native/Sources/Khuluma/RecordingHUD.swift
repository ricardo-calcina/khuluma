import AppKit
import KhulumaCore
import SwiftUI

/// The bottom-of-screen marker (Settings › Dictation › Show on-screen
/// indicator): a dark capsule that floats above everything on the screen
/// under the pointer. It never takes focus and never intercepts the mouse,
/// so delivery still pastes into the app in front.
final class RecordingHUD {
  /// Transparent padding around the capsule inside the panel, so the
  /// capsule's shadow is drawn in full instead of clipping to the view.
  static let margin: CGFloat = 16

  /// Driven on main only (AppController's status updates and its timers).
  final class Model: ObservableObject {
    enum State: Equatable {
      case hidden
      /// Empty levels = Reduce Motion: the view shows a still dot.
      case recording(elapsed: String, levels: [Float])
      case processing
      case error(String)
    }
    @Published var state: State
    init(state: State = .hidden) { self.state = state }
  }

  private let model = Model()
  private var panel: NSPanel?
  private var ticker: Timer?
  private var hideAfter: Timer?
  private var startedAt: Double?
  /// The indicator polls this while recording (the recorder's level).
  var level: () -> Float = { 0 }
  private var levels = LevelHistory(count: 9)
  /// The live ticker polls levels; under Reduce Motion it ticks elapsed only.
  private var metering = false

  /// Driven from `refreshStatus()`. `startedAt` is monotonic ms.
  func update(phase: ActivityStatus.Phase, recordingStartedAt: Double?, enabled: Bool) {
    startedAt = recordingStartedAt
    guard enabled else { hide(); return }
    switch phase {
    case .recording:
      hideAfter?.invalidate(); hideAfter = nil
      metering = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
      tick()
      // 15 Hz while metering (common modes, so an open menu can't stall
      // it); 0.5 s for elapsed time alone.
      let interval = metering ? 1.0 / 15 : 0.5
      if ticker == nil || ticker?.timeInterval != interval {
        ticker?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
      }
      show()
    case .processing:
      stopTicker()
      hideAfter?.invalidate(); hideAfter = nil
      model.state = .processing
      show()
    case .error(let message):
      stopTicker()
      model.state = .error(message)
      show()
      hideAfter?.invalidate()
      hideAfter = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
        self?.hide()
      }
    case .ready:
      hide()
    }
  }

  private func tick() {
    guard let startedAt else { return }
    let seconds = max(0, Int((monotonicMs() - startedAt) / 1000))
    let elapsed = String(format: "%d:%02d", seconds / 60, seconds % 60)
    if metering {
      levels.push(level())
      model.state = .recording(elapsed: elapsed, levels: levels.levels)
    } else {
      model.state = .recording(elapsed: elapsed, levels: [])
    }
  }

  private func stopTicker() {
    ticker?.invalidate()
    ticker = nil
    metering = false
  }

  private func show() {
    let panel = panel ?? makePanel()
    place(panel)
    guard !panel.isVisible else { return }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      panel.animator().alphaValue = 1
    }
  }

  private func hide() {
    stopTicker()
    hideAfter?.invalidate(); hideAfter = nil
    model.state = .hidden
    guard let panel, panel.isVisible else { return }
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.15
      panel.animator().alphaValue = 0
    }, completionHandler: {
      panel.orderOut(nil)
    })
  }

  private func makePanel() -> NSPanel {
    // The margin makes room for the capsule's shadow; the view itself draws
    // no background, so nothing shows around the capsule.
    let hosting = NSHostingView(rootView: RecordingHUDView(model: model).padding(Self.margin))
    let panel = HUDPanel(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                         styleMask: [.borderless, .nonactivatingPanel],
                         backing: .buffered, defer: false)
    panel.level = .statusBar
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    panel.contentView = hosting
    self.panel = panel
    return panel
  }

  /// The capsule — not the panel — centred, ~24 pt above the bottom of the
  /// visible frame of the screen under the mouse pointer.
  private func place(_ panel: NSPanel) {
    guard let hosting = panel.contentView else { return }
    hosting.layoutSubtreeIfNeeded()
    let size = hosting.fittingSize
    panel.setContentSize(size)
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    guard let frame = screen?.visibleFrame else { return }
    panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24 - Self.margin))
  }
}

/// Borderless and non-activating: it can never take key or main status.
private final class HUDPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// The capsule itself. One dark look in both appearances, like the system's
/// own HUDs, since it floats over other apps' content.
struct RecordingHUDView: View {
  @ObservedObject var model: RecordingHUD.Model

  var body: some View {
    Group {
      switch model.state {
      case .hidden:
        EmptyView()
      case .recording(let elapsed, let levels):
        capsule {
          if levels.isEmpty {
            Circle().fill(Ember.red).frame(width: 8, height: 8)
          } else {
            HStack(alignment: .center, spacing: 2) {
              ForEach(levels.indices, id: \.self) { index in
                Capsule()
                  .fill(Ember.vertical)
                  .frame(width: 2.5, height: 3 + CGFloat(levels[index]) * 11)
              }
            }
            .frame(height: 14)
            .animation(.linear(duration: 1.0 / 15), value: levels)
          }
          Text(elapsed)
            .font(.system(size: 12.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.92))
        }
        .accessibilityLabel("Recording, \(elapsed)")
      case .processing:
        capsule {
          SpinnerArc()
          Text("Transcribing")
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
        }
      case .error(let message):
        capsule(fits: false) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(Ember.accent)
          Text(message)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.92))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: 320, alignment: .leading)
        }
      }
    }
    .accessibilityElement(children: .combine)
  }

  /// `fits` sizes to the content; error text is capped instead so a long
  /// message can't stretch the capsule across the screen.
  private func capsule<Content: View>(fits: Bool = true, @ViewBuilder _ content: () -> Content) -> some View {
    HStack(spacing: 8) { content() }
      .modifier(FitIf(fits))
      .padding(.horizontal, 12)
      .frame(height: 30)
      .background(Capsule().fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.94)))
      .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
      .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
      .environment(\.colorScheme, .dark)
  }

  /// The processing arc: a white trim spinning once every 0.9 s, still
  /// under Reduce Motion.
  private struct SpinnerArc: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
      if reduceMotion {
        arc(angle: 0)
      } else {
        TimelineView(.animation) { context in
          arc(angle: context.date.timeIntervalSinceReferenceDate * 400)
        }
      }
    }

    private func arc(angle: Double) -> some View {
      Circle()
        .trim(from: 0, to: 0.7)
        .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        .frame(width: 12, height: 12)
        .rotationEffect(.degrees(angle.truncatingRemainder(dividingBy: 360)))
    }
  }

  private struct FitIf: ViewModifier {
    let fits: Bool
    init(_ fits: Bool) { self.fits = fits }
    func body(content: Content) -> some View {
      if fits { content.fixedSize() } else { content }
    }
  }
}
