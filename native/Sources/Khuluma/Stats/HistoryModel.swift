import AppKit
import KhulumaCore

/// The History tab's data: the dictation records on disk, searched on the
/// page. Loads happen off the main thread; a stale load is dropped.
@MainActor
final class HistoryModel: ObservableObject {
  @Published private(set) var items: [DictationHistory.Item] = []
  @Published var query = ""
  /// The row whose text was just copied (the checkmark feedback).
  @Published private(set) var copiedID: String?
  /// Rows clicked open to full text (the view toggles them).
  @Published var expanded: Set<String> = []
  /// Rows showing the raw transcript instead of the cleaned text.
  @Published var showingRaw: Set<String> = []
  /// Rows being transcribed again.
  @Published private(set) var transcribing: Set<String> = []
  /// A row's last Transcribe again failure, shown inline.
  @Published private(set) var rowMessages: [String: String] = [:]
  /// Transcribes a kept WAV (the pipeline, wired in AppController); nil
  /// hides the action. Called off the main thread.
  var transcribeAgain: ((URL) -> TranscribeAgainOutcome)?

  /// Where the records live; injectable so snapshots use fixtures.
  var directory = AppRuntimePaths.support.appendingPathComponent("history", isDirectory: true)
  /// The retention line's figure (0 = forever), refreshed on each load when provided.
  private(set) var retentionDays = 7
  /// Where the figure comes from (the settings store, wired in AppController).
  var retentionProvider: (() -> Int)?
  /// Loads the items; injectable for previews (never reads real history).
  var loadItems: (URL) -> [DictationHistory.Item] = { DictationHistory.load(directory: $0) }

  private var generation = 0

  var filtered: [DictationHistory.Item] { DictationHistory.filter(items, query: query) }

  var days: [DictationHistory.Day] {
    DictationHistory.days(filtered, now: Date(), calendar: .current, locale: .current)
  }

  /// Reload from disk (or the injected loader); publishes on main.
  func reload() {
    generation += 1
    let generation = generation, directory = directory, loadItems = loadItems
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let items = loadItems(directory)
      DispatchQueue.main.async {
        guard let self, self.generation == generation else { return }
        self.items = items
        if let days = self.retentionProvider?() { self.retentionDays = days }
      }
    }
  }

  /// Previews and snapshots set fixture items directly (reload is async).
  func adopt(_ items: [DictationHistory.Item]) { self.items = items }

  /// Called after a take settles: reload only while the page is showing.
  func reloadIfShowing(_ page: AppNavigation.Page) {
    if page == .history { reload() }
  }

  /// The dictation's text onto the clipboard, with the check feedback.
  func copy(_ item: DictationHistory.Item) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(item.text, forType: .string)
    copiedID = item.id
    let id = item.id
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      if self?.copiedID == id { self?.copiedID = nil }
    }
  }

  /// Transcribes the row's kept WAV again, replaces the entry's text (the
  /// old pair goes to `versions`) and reloads. The clipboard is never
  /// touched: a live take may be between its clipboard write and Cmd-V.
  /// The row's copy button copies the new text. On any
  /// failure the entry is left as it was and the row says why.
  func transcribe(_ item: DictationHistory.Item) {
    guard let wav = item.keptWAV, let transcribeAgain, !transcribing.contains(item.id) else { return }
    transcribing.insert(item.id)
    rowMessages[item.id] = nil
    let url = directory.appendingPathComponent(item.id), id = item.id
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      var failure: String?
      var saved = false
      switch transcribeAgain(wav) {
      case .failed(let why): failure = why
      case .noSpeech: failure = "No speech found"
      case .text(let raw, let processed):
        do {
          try HistoryRevision.replace(at: url, raw: raw, processed: processed)
          saved = true
        } catch {
          failure = "Couldn't save the new text"
        }
      }
      DispatchQueue.main.async {
        guard let self else { return }
        self.transcribing.remove(id)
        self.rowMessages[id] = failure
        if saved {
          self.showingRaw.remove(id)
          self.reload()
        }
      }
    }
  }
}
