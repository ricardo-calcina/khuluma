import AppKit
import KhulumaCore

final class VocabularyModel: ObservableObject {
  enum Section: String, CaseIterable, Identifiable {
    case fillers = "Fillers", brands = "Brands", words = "Other words"
    var id: String { rawValue }
  }
  struct Entry: Identifiable { var heard: String; var write: String; var id: String { heard } }
  @Published var document = VocabularySheet.empty
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
  @Published var confirmDiscard = false
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
  func changeSection(_ value: Section) { guard !formDirty else { return }; section = value; clearFields() }
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
  func save() {
    guard canEdit, !formDirty, let baseline else { return }
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
