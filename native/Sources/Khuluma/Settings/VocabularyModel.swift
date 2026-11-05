import AppKit
import KhulumaCore

final class VocabularyModel: ObservableObject {
  typealias Section = VocabularySheet.Section
  typealias Entry = VocabularySheet.Row
  /// The row being edited in place: an existing entry, or the new row that
  /// + adds at the end of the table.
  enum Edit: Equatable { case existing(String), new }
  /// The new row's table id. Validation rejects control characters, so no
  /// saved entry can have it.
  static let newRowID = "\u{1}new"
  @Published var document = VocabularySheet.empty { didSet { checkExamples() } }
  /// Failing examples' heard text → what cleanup gives now, against the draft.
  @Published private(set) var exampleFailures: [String: String] = [:]
  /// Recent dictations' first-pass text, newest first, for new examples.
  @Published var recent: [String] = []
  @Published var confirmFailingSave = false
  @Published var section = Section.fillers
  @Published private(set) var selection: Set<String> = []
  @Published private(set) var editing: Edit?
  /// The edited row's text while it is being typed.
  @Published var heard = "" { didSet { if heard != oldValue { clearEditError() } } }
  @Published var write = "" { didSet { if write != oldValue { clearEditError() } } }
  /// Why the edited row could not go into the draft, such as a duplicate.
  @Published private(set) var editError: String?
  @Published var query = ""
  /// Command-F bumps this to focus the search field (the Command Line Tools
  /// have no SwiftUI macro plugin for @State).
  @Published var searchRequest = 0
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
  var entries: [Entry] { document.rows(section) }

  /// Cleanup as a take would run it now, except with the draft vocabulary.
  /// Nil until settings load or when only the CLI can clean (non-C locale).
  private var pipeline: TextPipeline? {
    settings.config.map { TextPipeline(settings: $0.cleanup) }.flatMap { $0.settings.requiresCLI ? nil : $0 }
  }

  private func checkExamples() {
    let failures = pipeline?.failingExamples(document) ?? []
    exampleFailures = Dictionary(failures.map { ($0.example.said, $0.got) }, uniquingKeysWith: { first, _ in first })
  }

  /// The one selected entry, when exactly one saved row is selected.
  var selectedEntry: Entry? {
    guard selection.count == 1, let id = selection.first else { return nil }
    return entries.first { $0.heard == id }
  }

  /// The Said text the Examples inspector describes: the row being typed, or
  /// the one selected example.
  private var inspectedSaid: String? {
    guard section == .examples else { return nil }
    return editing != nil ? heard : selectedEntry?.heard
  }

  /// What the draft does to the inspected Said text (Examples only).
  var preview: (text: String, changes: [TextChange])? {
    guard let said = inspectedSaid, !said.trimmingCharacters(in: .whitespaces).isEmpty, let pipeline else { return nil }
    switch pipeline.preview(transcript: said, sheet: document) {
    case .needsCLI: return nil
    case .noSpeech: return ("", [TextChange(before: said, after: "")])
    case .text(_, let text): return (text, TextChange.between(said, text))
    }
  }

  /// The Expect text the inspector compares against the preview.
  var inspectedExpect: String? { editing != nil ? write : selectedEntry?.write }

  /// For the selected failing example: the rule that would make it pass.
  var suggestedRule: VocabularySheet.Correction? {
    guard section == .examples, editing == nil, let entry = selectedEntry,
          let got = exampleFailures[entry.heard] else { return nil }
    return TextChange.suggestedRule(got: got, expected: entry.write)
  }

  func addRule(_ rule: VocabularySheet.Correction) {
    guard canEdit else { return }
    var next = document
    next.words.append(rule)
    let keep = selection
    do { try change(next); selection = keep; message = "Added “\(rule.heard)” → “\(rule.write)” to Other words." }
    catch { report(error) }
  }

  /// Use as Expected: into the row being typed, or straight into the draft.
  func useAsExpected(_ text: String) {
    if editing != nil { write = text; return }
    guard canEdit, section == .examples, let entry = selectedEntry else { return }
    commit(Entry(heard: entry.heard, write: text), replacing: entry.heard)
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
  /// The table's rows: the filtered entries, plus the new row while it is typed.
  var rows: [Entry] { editing == .new ? filtered + [Entry(heard: Self.newRowID)] : filtered }

  private var editingOriginal: String? {
    if case .existing(let id) = editing { return id }
    return nil
  }
  /// The edited row differs from what the draft holds.
  var formDirty: Bool {
    switch editing {
    case nil: return false
    case .new: return !heard.isEmpty || !write.isEmpty
    case .existing(let id):
      guard let entry = entries.first(where: { $0.heard == id }) else { return true }
      return heard != entry.heard || write != entry.write
    }
  }
  var canEdit: Bool { loaded && !working && !settings.recording && !settings.saving }
  var canUndo: Bool { canEdit && editing == nil && !undoStack.isEmpty }

  var fieldsComplete: Bool {
    !heard.trimmingCharacters(in: .whitespaces).isEmpty
      && (section == .fillers || !write.trimmingCharacters(in: .whitespaces).isEmpty)
  }

  /// Typing a fix clears the row's warning and its status message.
  private func clearEditError() {
    guard editError != nil else { return }
    editError = nil; message = nil; failed = false
  }
  /// Starts editing a saved row in place. False if the row being typed
  /// cannot be settled, such as a duplicate.
  @discardableResult func beginEdit(_ id: String) -> Bool {
    guard canEdit, let entry = entries.first(where: { $0.heard == id }) else { return false }
    if editing == .existing(id) { return true }
    settleFields()
    guard editing == nil else { return false }
    editing = .existing(id); heard = entry.heard; write = entry.write
    selection = [id]
    return true
  }
  /// + and New from Recent: a new row at the end, optionally with Said text.
  @discardableResult func beginNew(heard text: String = "") -> Bool {
    guard canEdit else { return false }
    settleFields()
    guard editing == nil else { return false }
    editing = .new; heard = text; write = ""
    selection = [Self.newRowID]
    return true
  }
  /// Escape: leaves the draft as it was and drops a new row.
  func cancelEdit() {
    if editing == .new { selection = [] }
    editing = nil; heard = ""; write = ""; editError = nil
  }
  /// Return in the last cell, or moving on: puts a finished row into the
  /// draft (Undo can take it back), drops an unfinished one. Only an invalid
  /// row, such as a duplicate, stays open with its warning.
  func settleFields() {
    guard editing != nil else { return }
    guard formDirty else { cancelEdit(); return }
    if fieldsComplete { addOrUpdate() } else { cancelEdit() }
  }
  /// The table's selection. Selecting another row settles the one being
  /// typed; an invalid row keeps the selection.
  func select(_ value: Set<String>) {
    guard value != selection else { return }
    if editing != nil {
      if value == [editingOriginal ?? Self.newRowID] { return }
      settleFields()
      guard editing == nil else { return }
    }
    selection = value.filter { id in entries.contains { $0.heard == id } }
  }
  func changeSection(_ value: Section) {
    settleFields()
    guard editing == nil else { return }
    section = value; selection = []
    if value == .examples { loadRecent() }
  }
  func report(_ error: Error) { failed = true; message = error.localizedDescription }
  private func change(_ value: VocabularySheet) throws {
    let validated = try value.validated()
    undoStack.append(document)
    document = validated
    editing = nil; heard = ""; write = ""; editError = nil
    failed = false; message = nil
  }
  private func commit(_ row: Entry, replacing original: String?) {
    do {
      try change(document.upserting(row, in: section, replacing: original))
      // Validation trims rules; select the row as saved.
      let id = section == .examples ? row.heard : row.heard.trimmingCharacters(in: .whitespacesAndNewlines)
      selection = entries.contains { $0.heard == id } ? [id] : []
    } catch {
      report(error)
      if editing != nil { editError = error.localizedDescription }
    }
  }
  func addOrUpdate() {
    guard canEdit, editing != nil else { return }
    commit(Entry(heard: heard, write: section == .fillers ? "" : write), replacing: editingOriginal)
  }
  /// − and Delete: removes the selected rows, or drops the new row.
  func remove() {
    guard canEdit else { return }
    if editing != nil { cancelEdit(); if selection.isEmpty { return } }
    let ids = selection.subtracting([Self.newRowID])
    guard !ids.isEmpty else { return }
    let next = VocabularySheet.selectionAfterRemoving(ids, from: filtered)
    do {
      try change(document.removing(ids, from: section))
      selection = next.map { [$0] } ?? []
      message = ids.count == 1 ? "Entry removed. Undo restores it." : "\(ids.count.formatted()) entries removed. Undo restores them."
    } catch { report(error) }
  }
  func undo() {
    guard canUndo, let previous = undoStack.popLast() else { return }
    document = previous; selection = []; failed = false; message = "Previous vocabulary restored in the draft."
  }
  /// Revert: reads the saved vocabulary again, confirming first when that
  /// would lose edits.
  func revert() {
    if dirty || formDirty { confirmReload = true } else { load() }
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

  /// Takes a freshly read vocabulary as the saved baseline and the draft.
  func adopt(_ snapshot: VocabularySnapshot) {
    baseline = snapshot; document = snapshot.document; loaded = true
    undoStack = []; cancelEdit(); selection = []; message = nil
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
        case .success(let snapshot): self.adopt(snapshot)
        case .failure(let error): self.report(error)
        }
      }
    }
  }
  /// Saving with failing examples asks first: they show a rule change broke
  /// something that used to come out right.
  func save(confirmed: Bool = false) {
    settleFields()
    guard canEdit, editing == nil, let baseline else { return }
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
