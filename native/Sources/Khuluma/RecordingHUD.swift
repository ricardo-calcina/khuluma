import AppKit
import KhulumaCore
import SwiftUI

/// The bottom-of-screen marker (Settings › Dictation › Show on-screen
/// indicator): a capsule that floats above everything on the screen under
/// the pointer. It never takes focus and never intercepts the mouse, so
/// delivery still pastes into the app in front.
final class RecordingHUD {
  /// Driven on main only (AppController's status updates and its timers).
  final class Model: ObservableObject {
    enum State: Equatable {
      case hidden
      case recording(elapsed: String)
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

  /// Driven from `refreshStatus()`. `startedAt` is monotonic ms.
  func update(phase: ActivityStatus.Phase, recordingStartedAt: Double?, enabled: Bool) {
    startedAt = recordingStartedAt
    guard enabled else { hide(); return }
    switch phase {
    case .recording:
      hideAfter?.invalidate(); hideAfter = nil
      tick()
      if ticker == nil {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.tick() }
        }
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
        MainActor.assumeIsolated { self?.hide() }
      }
    case .ready:
      hide()
    }
  }

  private func tick() {
    guard let startedAt else { return }
    let seconds = max(0, Int((monotonicMs() - startedAt) / 1000))
    model.state = .recording(elapsed: String(format: "%d:%02d", seconds / 60, seconds % 60))
  }

  private func stopTicker() {
    ticker?.invalidate()
    ticker = nil
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
    let hosting = NSHostingView(rootView: RecordingHUDView(model: model))
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

  /// Centred, ~24 pt above the bottom of the visible frame of the screen
  /// under the mouse pointer.
  private func place(_ panel: NSPanel) {
    guard let hosting = panel.contentView else { return }
    hosting.layoutSubtreeIfNeeded()
    let size = hosting.fittingSize
    panel.setContentSize(size)
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    guard let frame = screen?.visibleFrame else { return }
    panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 24))
  }
}

/// Borderless and non-activating: it can never take key or main status.
private final class HUDPanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

/// The capsule: red dot and elapsed time while recording, a spinner while
/// transcribing, the error briefly. Ember red only for the recording dot.
struct RecordingHUDView: View {
  @ObservedObject var model: RecordingHUD.Model

  var body: some View {
    Group {
      switch model.state {
      case .hidden:
        EmptyView()
      case .recording(let elapsed):
        capsule {
          Circle().fill(Ember.red).frame(width: 8, height: 8)
          Text(elapsed)
            .font(.system(size: 13, weight: .medium).monospacedDigit())
        }
      case .processing:
        capsule {
          ProgressView()
            .controlSize(.small)
            .scaleEffect(0.7)
            .frame(width: 12, height: 12)
          Text("Transcribing")
            .font(.system(size: 13, weight: .medium))
        }
      case .error(let message):
        capsule(fits: false) {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 11))
            .foregroundStyle(Ember.accent)
          Text(message)
            .font(.system(size: 13, weight: .medium))
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
    HStack(spacing: 7) { content() }
      .modifier(FitIf(fits))
      .padding(.horizontal, 12)
      .padding(.vertical, 7)
      .background(Capsule().fill(Surface.canvas))
      .overlay(Capsule().strokeBorder(Ink.rule, lineWidth: 0.5))
      .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
  }

  private struct FitIf: ViewModifier {
    let fits: Bool
    init(_ fits: Bool) { self.fits = fits }
    func body(content: Content) -> some View {
      if fits { content.fixedSize() } else { content }
    }
  }
}
