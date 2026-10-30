import AppKit
import KhulumaCore

final class VocabularyModel: ObservableObject {
  enum Section: String, CaseIterable, Identifiable {
    case fillers = "Fillers", brands = "Brands", words = "Other words", examples = "Examples"
    var id: String { rawValue }
  }
  struct Entry: Identifiable { var heard: String; var write: String; var id: String { heard } }
  @Published var document = VocabularySheet.empty { didSet { checkExamples() } }
  /// Failing examples' heard text → what cleanup gives now, against the draft.
  @Published private(set) var exampleFailures: [String: String] = [:]
  /// Recent dictations' first-pass text, newest first, for new examples.
  @Published var recent: [String] = []
  @Published var confirmFailingSave = false
  @Published var section = Section.fillers
  @Published var selected: String?
  @Published var query = ""
  @Published var heard = ""
  @Published var write = ""
  @Published var working = false
  @Published var loaded = false
  @Published var message: String?
  @Published var failed = false
  @Published var imported: VocabularySheet?
  @Published var undoStack: [VocabularySheet] = []
  @Published var confirmReload = false
  private var baseline: VocabularySnapshot?
  private let settings: SettingsModel
  init(settings: SettingsModel) { self.settings = settings }

  var dirty: Bool { baseline.map { $0.document != document } ?? false }
  var entries: [Entry] {
    switch section {
    case .fillers: return document.fillers.map { Entry(heard: $0, write: "") }
    case .brands: return document.brands.map { Entry(heard: $0.heard, write: $0.write) }
    case .words: return document.words.map { Entry(heard: $0.heard, write: $0.write) }
    case .examples: return (document.examples ?? []).map { Entry(heard: $0.said, write: $0.expect) }
    }
  }

  /// Cleanup as a take would run it now, except with the draft vocabulary.
  /// Nil until settings load or when only the CLI can clean (non-C locale).
  private var pipeline: TextPipeline? {
    settings.config.map { TextPipeline(settings: $0.cleanup) }.flatMap { $0.settings.requiresCLI ? nil : $0 }
  }

  private func checkExamples() {
    let failures = pipeline?.failingExamples(document) ?? []
    exampleFailures = Dictionary(failures.map { ($0.example.said, $0.got) }, uniquingKeysWith: { first, _ in first })
  }

  /// What the draft does to the text in the Heard field (Examples only).
  var preview: (text: String, changes: [TextChange])? {
    guard section == .examples, !heard.trimmingCharacters(in: .whitespaces).isEmpty, let pipeline else { return nil }
    switch pipeline.preview(transcript: heard, sheet: document) {
    case .needsCLI: return nil
    case .noSpeech: return ("", [TextChange(before: heard, after: "")])
    case .text(_, let text): return (text, TextChange.between(heard, text))
    }
  }

  /// For the selected failing example: the rule that would make it pass.
  var suggestedRule: VocabularySheet.Correction? {
    guard section == .examples, let selected, let got = exampleFailures[selected],
          let entry = entries.first(where: { $0.heard == selected }) else { return nil }
    return TextChange.suggestedRule(got: got, expected: entry.write)
  }

  func addRule(_ rule: VocabularySheet.Correction) {
    guard canEdit else { return }
    var next = document
    next.words.append(rule)
    let keep = selected
    do { try change(next); select(keep); message = "Added “\(rule.heard)” → “\(rule.write)” to Other words." }
    catch { report(error) }
  }

  func loadRecent() {
    guard recent.isEmpty else { return }
    let operation = settings.onLoadRecentDictations
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let texts = (try? operation()) ?? []
      DispatchQueue.main.async { self?.recent = texts }
    }
  }
  var filtered: [Entry] {
    entries.filter { query.isEmpty || $0.heard.localizedCaseInsensitiveContains(query) || $0.write.localizedCaseInsensitiveContains(query) }
  }
  var formDirty: Bool {
    if let entry = entries.first(where: { $0.heard == selected }) {
      return heard != entry.heard || write != entry.write
    }
    return !heard.isEmpty || !write.isEmpty
  }
  var canEdit: Bool { loaded && !working && !settings.recording && !settings.saving }

  func clearFields() { selected = nil; heard = ""; write = "" }
  func select(_ value: String?) {
    guard !formDirty else { return }
    selected = value
    let entry = entries.first { $0.heard == value }
    heard = entry?.heard ?? ""; write = entry?.write ?? ""
  }
  func changeSection(_ value: Section) {
    guard !formDirty else { return }
    section = value; clearFields()
    if value == .examples { loadRecent() }
  }
  func report(_ error: Error) { failed = true; message = error.localizedDescription }
  private func change(_ value: VocabularySheet) throws {
    let validated = try value.validated()
    undoStack.append(document)
    document = validated
    clearFields(); failed = false; message = "Changes are ready to save."
  }
  func addOrUpdate() {
    guard canEdit else { return }
    var next = document
    let entry = VocabularySheet.Correction(heard: heard, write: write)
    switch section {
    case .fillers:
      if let index = next.fillers.firstIndex(where: { $0 == selected }) { next.fillers[index] = heard }
      else { next.fillers.append(heard) }
    case .brands:
      if let index = next.brands.firstIndex(where: { $0.heard == selected }) { next.brands[index] = entry }
      else { next.brands.append(entry) }
    case .words:
      if let index = next.words.firstIndex(where: { $0.heard == selected }) { next.words[index] = entry }
      else { next.words.append(entry) }
    case .examples:
      var examples = next.examples ?? []
      let example = VocabularySheet.Example(said: heard, expect: write)
      // Heard text identifies an example; a repeat replaces it.
      if let index = examples.firstIndex(where: { $0.said == (selected ?? heard) }) { examples[index] = example }
      else { examples.append(example) }
      next.examples = examples
    }
    do { try change(next) } catch { report(error) }
  }
  func remove() {
    guard canEdit, let selected else { return }
    var next = document
    switch section {
    case .fillers: next.fillers.removeAll { $0 == selected }
    case .brands: next.brands.removeAll { $0.heard == selected }
    case .words: next.words.removeAll { $0.heard == selected }
    case .examples: next.examples?.removeAll { $0.said == selected }
    }
    do { try change(next) } catch { report(error) }
  }
  func undo() {
    guard canEdit, let previous = undoStack.popLast() else { return }
    document = previous; clearFields(); failed = false; message = "Previous vocabulary restored in the draft."
  }
  func useImport() {
    guard let imported, canEdit else { return }
    do { try change(imported); self.imported = nil; query = "" } catch { report(error) }
  }
  var importSummary: String {
    guard let imported else { return "" }
    func rules(_ sheet: VocabularySheet) -> [String: String] {
      var result = Dictionary(uniqueKeysWithValues: sheet.fillers.map { ("Fillers: " + $0, "") })
      for rule in sheet.brands { result["Brands: " + rule.heard] = rule.write }
      for rule in sheet.words { result["Other words: " + rule.heard] = rule.write }
      for example in sheet.examples ?? [] { result["Examples: " + example.said] = example.expect }
      return result
    }
    let old = rules(document), new = rules(imported)
    let added = new.keys.filter { old[$0] == nil }.count
    let removed = old.keys.filter { new[$0] == nil }.count
    let changed = new.keys.filter { old[$0] != nil && old[$0] != new[$0] }.count
    func count(_ value: Int, _ word: String) -> String { "\(value.formatted()) \(word)\(value == 1 ? "" : "s")" }
    return "\(count(imported.fillers.count, "filler")), \(count(imported.brands.count, "brand")) and \(count(imported.words.count, "other word")).\n\n\(added.formatted()) added, \(changed.formatted()) changed, \(removed.formatted()) removed. Review the draft, then Save Changes to apply it."
  }

  func load() {
    guard !working else { return }
    working = true; failed = false; message = nil
    let operation = settings.onLoadVocabulary
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = Result { try operation() }
      DispatchQueue.main.async {
        guard let self else { return }
        self.working = false
        switch result {
        case .success(let snapshot):
          self.baseline = snapshot; self.document = snapshot.document; self.loaded = true
          self.undoStack = []; self.clearFields(); self.message = nil
        case .failure(let error): self.report(error)
        }
      }
    }
  }
  /// Saving with failing examples asks first: they show a rule change broke
  /// something that used to come out right.
  func save(confirmed: Bool = false) {
    guard canEdit, !formDirty, let baseline else { return }
    if !confirmed, !exampleFailures.isEmpty {
      confirmFailingSave = true
      return
    }
    let snapshot = VocabularySnapshot(document: document, revision: baseline.revision)
    working = true; settings.saving = true; message = nil
    let operation = settings.onSaveVocabulary
    let settings = self.settings
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = Result { try operation(snapshot) }
      DispatchQueue.main.async {
        settings.saving = false
        guard let self else { return }
        self.working = false
        switch result {
        case .success(let saved):
          self.baseline = saved; self.document = saved.document; self.failed = false
          self.message = "Vocabulary saved. Applies to your next dictation."
        case .failure(let error): self.report(error)
        }
      }
    }
  }
  func importData(_ data: Data) {
    guard canEdit else { return }
    working = true; message = nil
    let operation = settings.onValidateVocabulary
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let result = Result { try operation(data) }
      DispatchQueue.main.async {
        guard let self else { return }
        self.working = false
        switch result {
        case .success(let document): self.imported = document
        case .failure(let error): self.report(error)
        }
      }
    }
  }
}
