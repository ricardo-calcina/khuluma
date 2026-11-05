import AppKit
import KhulumaCore
import SwiftUI
import UniformTypeIdentifiers

/// The Vocabulary tab: a standard Mac list editor. The window owns the
/// model, so a draft survives switching tabs until it is saved or reverted.
struct VocabularyView: View {
  @ObservedObject var model: VocabularyModel
  @ObservedObject var settings: SettingsModel
  @FocusState private var focus: Column?
  private enum Column: Hashable { case heard, write }
  private typealias Entry = VocabularyModel.Entry

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        Picker("Section", selection: Binding(get: { model.section }, set: { model.changeSection($0) })) {
          ForEach(VocabularyModel.Section.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize().disabled(!model.canEdit)
        Spacer(minLength: 0)
        SearchField(text: $model.query, focusRequest: model.searchRequest)
          .frame(minWidth: 120, idealWidth: 170, maxWidth: 170)
          .disabled(model.working)
      }
      .padding(.bottom, 10)
      VStack(spacing: 0) {
        table
        controlBar
      }
      if model.section == .examples {
        inspector.padding(.top, 8).disabled(!model.canEdit)
      }
      HStack(spacing: 8) {
        status
        Spacer(minLength: 8)
        Button("Revert") { model.revert() }
          .disabled(!model.loaded || model.working)
          .help("Discard the draft and read the saved vocabulary again")
        Button("Save Changes") { model.save() }
          .keyboardShortcut("s")
          .buttonStyle(.borderedProminent)
          .disabled(!model.canEdit || model.editError != nil || !(model.dirty || (model.formDirty && model.fieldsComplete)))
          .help("Save Changes (⌘S)")
      }
      .frame(minHeight: 30)
      .padding(.top, 12)
    }
    .padding(.horizontal, 20).padding(.vertical, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .background { shortcuts }
    .onAppear { if !model.loaded { model.load() } }
    .onChange(of: focus) { _, value in
      if let value { model.editingWrite = value == .write; return }
      // Leaving the edited row settles it, like any other move. Losing focus
      // to the dictation lock keeps the row and its text instead.
      guard model.editing != nil, model.canEdit else { return }
      DispatchQueue.main.async { if focus == nil && model.canEdit { model.settleFields() } }
    }
    .onChange(of: model.canEdit) { _, editable in
      // Dictation finished: carry on typing where the row was left.
      guard editable, model.editing != nil else { return }
      let column: Column = model.editingWrite && model.section != .fillers ? .write : .heard
      DispatchQueue.main.async {
        focus = column
        // Focusing selects the whole text; put the cursor back at the end.
        DispatchQueue.main.async { (NSApp.keyWindow?.firstResponder as? NSTextView)?.moveToEndOfDocument(nil) }
      }
    }
    .confirmationDialog("Revert to the saved vocabulary?", isPresented: $model.confirmReload) {
      Button("Revert and Discard Draft", role: .destructive) { model.load() }
      Button("Keep Editing", role: .cancel) {}
    } message: { Text("This discards unsaved entries and reads the saved vocabulary again.") }
    .confirmationDialog("Some examples no longer match", isPresented: $model.confirmFailingSave) {
      Button("Save Anyway") { model.save(confirmed: true) }
      Button("Keep Editing", role: .cancel) {}
    } message: {
      Text("\(model.exampleFailures.count.formatted()) \(model.exampleFailures.count == 1 ? "example gives" : "examples give") different text with this vocabulary. Open Examples to see what changed.")
    }
    .confirmationDialog("Use imported vocabulary?", isPresented: Binding(
      get: { model.imported != nil }, set: { if !$0 { model.imported = nil } })) {
        Button("Use Imported Vocabulary") { model.useImport() }
        Button("Cancel", role: .cancel) { model.imported = nil }
      } message: { Text(model.importSummary) }
  }

  // MARK: Table

  @ViewBuilder private var table: some View {
    let selection = Binding(get: { model.selection }, set: { model.select($0) })
    Group {
      switch model.section {
      case .fillers:
        Table(model.rows, selection: selection) {
          TableColumn("Filler") { cell($0, .heard) }
        }
      case .examples:
        Table(model.rows, selection: selection) {
          TableColumn("") { exampleStatus($0) }.width(16)
          TableColumn("Said") { cell($0, .heard) }
          TableColumn("Expect") { cell($0, .write) }
        }
      case .brands, .words:
        Table(model.rows, selection: selection) {
          TableColumn("Heard as") { cell($0, .heard) }
          TableColumn("Write as") { cell($0, .write) }
        }
      }
    }
    .tableStyle(.bordered(alternatesRowBackgrounds: true))
    .frame(minHeight: 120)
    .background(TableFocus(request: model.tableFocusRequest))
    .contextMenu(forSelectionType: String.self) { ids in
      let saved = ids.subtracting([VocabularyModel.newRowID])
      if saved.count == 1, let id = saved.first { Button("Edit") { edit(id) } }
      if !saved.isEmpty {
        Button(saved.count == 1 ? "Remove" : "Remove \(saved.count.formatted()) Entries") {
          model.select(saved); model.remove()
        }
      }
    } primaryAction: { ids in
      if ids.count == 1, let id = ids.first { edit(id) }
    }
    .onKeyPress(.return) {
      guard model.editing == nil, model.selection.count == 1, let id = model.selection.first else { return .ignored }
      edit(id)
      return .handled
    }
    .onKeyPress(.escape) {
      // Escape cancels an open row; otherwise the window takes it (back to
      // Stats). The window also asks the model first, as a backstop.
      model.escape() ? .handled : .ignored
    }
    .onDeleteCommand { model.remove() }
    .overlay {
      if model.loaded && model.rows.isEmpty {
        Text(model.query.isEmpty ? "No entries in this section. Click + to add one." : "No matching entries.")
          .font(.callout).foregroundStyle(.secondary).padding().allowsHitTesting(false)
      }
    }
    .disabled(!model.canEdit)
  }

  private func isEditing(_ row: Entry) -> Bool {
    switch model.editing {
    case .new: return row.id == VocabularyModel.newRowID
    case .existing(let id): return row.id == id
    case nil: return false
    }
  }

  /// A cell edits in place while its row is open; otherwise plain text.
  @ViewBuilder private func cell(_ row: Entry, _ column: Column) -> some View {
    if isEditing(row) {
      HStack(spacing: 4) {
        TextField(title(column), text: column == .heard ? $model.heard : $model.write,
                  prompt: Text(placeholder(column)))
          .textFieldStyle(.plain)
          .focused($focus, equals: column)
          .onSubmit { submit(from: column) }
          .onExitCommand { _ = model.escape() }
          .accessibilityLabel(title(column))
        if column == .heard, model.section != .examples, let error = model.editError { warning(error) }
      }
    } else {
      let text = column == .heard ? row.heard : row.write
      Text(text).lineLimit(1).truncationMode(.tail)
        .help(text.count > 40 ? text : "")
        .accessibilityLabel(column == .heard ? rowLabel(row) : text)
    }
  }

  @ViewBuilder private func exampleStatus(_ row: Entry) -> some View {
    if isEditing(row) {
      if let error = model.editError { warning(error) }
    } else {
      let got = model.exampleFailures[row.heard]
      Image(systemName: got == nil ? "checkmark.circle" : "xmark.circle.fill")
        .foregroundStyle(got == nil ? Color.secondary : Color.red)
        .help(got.map { "Now gives: \($0.isEmpty ? "no speech" : $0)" } ?? "Passes with this draft")
        .accessibilityLabel(got == nil ? "Passes" : "Fails")
    }
  }

  private func warning(_ message: String) -> some View {
    Image(systemName: "exclamationmark.triangle.fill").symbolRenderingMode(.multicolor)
      .help(message).accessibilityLabel("Warning: \(message)")
  }

  // MARK: +/− bar

  private var controlBar: some View {
    HStack(spacing: 0) {
      barButton("plus", label: "Add entry") { add() }
        .disabled(!model.canEdit)
      Divider().frame(height: 14)
      barButton("minus", label: "Remove selected entries") { model.remove() }
        .disabled(!model.canEdit || (model.selection.isEmpty && model.editing == nil))
      Divider().frame(height: 14)
      actionMenu
      Spacer(minLength: 8)
      Text("\(model.filtered.count.formatted()) of \(model.entries.count.formatted()) \(model.entries.count == 1 ? "entry" : "entries")")
        .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        .padding(.trailing, 8)
    }
    .frame(height: 22)
    .background(Color(nsColor: .controlBackgroundColor))
    .overlay { Rectangle().strokeBorder(Color(nsColor: .gridColor), lineWidth: 1) }
    .padding(.top, -1)
  }

  private func barButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 11, weight: .medium))
        .frame(width: 26, height: 22).contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(label).accessibilityLabel(label)
  }

  private var actionMenu: some View {
    Menu {
      if model.section == .examples {
        Menu("New from Recent") {
          ForEach(model.recent, id: \.self) { text in
            Button(String(text.prefix(80)) + (text.count > 80 ? "…" : "")) { newExample(text) }
          }
        }
        .disabled(model.recent.isEmpty || !model.canEdit)
        Divider()
      }
      Button("Undo") { model.undo() }.disabled(!model.canUndo)
      Divider()
      Button("Import…") { if model.settleFields() { chooseImport() } }.disabled(!model.canEdit)
      Button(model.dirty ? "Export Draft…" : "Export…") { if model.settleFields() { export() } }
        .disabled(!model.loaded || model.working)
      Divider()
      Button("Revert to Saved…") { model.revert() }.disabled(!model.loaded || model.working)
    } label: {
      Image(systemName: "ellipsis.circle")
    }
    .menuStyle(.borderlessButton)
    .fixedSize()
    .padding(.horizontal, 6)
    .help("Undo, import, export and revert")
    .accessibilityLabel("Vocabulary actions")
  }

  // MARK: Examples inspector

  /// For the selected or edited example: what the draft gives (Use as
  /// Expected) or, for a failing one, the one-rule fix (Add Rule).
  private var inspector: some View {
    HStack(alignment: .firstTextBaseline, spacing: 6) {
      if let rule = model.suggestedRule {
        Text("Fails. Add “\(rule.heard)” → “\(rule.write)”?").lineLimit(1)
        Spacer(minLength: 4)
        Button("Add Rule") { model.addRule(rule) }.controlSize(.small)
      } else if let preview = model.preview {
        Text(preview.text.isEmpty ? "Gives no speech." : "Gives: \(preview.text)")
          .lineLimit(2).textSelection(.enabled)
          .help(preview.changes.map { "\($0.before.isEmpty ? "+" : $0.before) → \($0.after.isEmpty ? "removed" : $0.after)" }
            .joined(separator: "\n"))
        Spacer(minLength: 4)
        if model.inspectedExpect != preview.text {
          Button("Use as Expected") { model.useAsExpected(preview.text) }.controlSize(.small)
        }
      } else {
        Text("Examples are checked against your vocabulary before every save. Cleanup never uses them as rules.")
      }
    }
    .font(.caption).foregroundStyle(.secondary)
    .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
  }

  // MARK: Status

  @ViewBuilder private var status: some View {
    Group {
      if settings.recording {
        Label("Editing resumes when dictation finishes.", systemImage: "mic.fill")
      } else if model.working {
        HStack(spacing: 6) {
          ProgressView().controlSize(.small)
          Text(model.loaded ? "Updating vocabulary…" : "Loading vocabulary…")
        }
        .accessibilityElement(children: .combine)
      } else if let message = model.message {
        Label(message, systemImage: model.failed ? "exclamationmark.triangle" : "checkmark.circle")
          .foregroundStyle(model.failed ? Color.primary : Color.secondary)
          .textSelection(.enabled).accessibilityLabel(message)
      } else if model.dirty {
        Text("Unsaved changes")
      }
    }
    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
  }

  /// Command-F and Command-Z. Undo stays off while a row is typed, so the
  /// text field keeps its own undo.
  private var shortcuts: some View {
    ZStack {
      Button("Find") { model.searchRequest += 1 }.keyboardShortcut("f")
      Button("Undo") { model.undo() }.keyboardShortcut("z").disabled(!model.canUndo)
    }
    .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
  }

  // MARK: Actions

  private func edit(_ id: String, column: Column = .heard) {
    guard model.beginEdit(id) else { return }
    DispatchQueue.main.async { focus = column }
  }
  private func add() {
    guard model.beginNew() else { return }
    DispatchQueue.main.async { focus = .heard }
  }
  private func newExample(_ text: String) {
    guard model.beginNew(heard: text) else { return }
    DispatchQueue.main.async { focus = .write }
  }

  /// Return ends the edit; with a cell still empty it moves there instead.
  private func submit(from column: Column) {
    if model.formDirty && !model.fieldsComplete {
      focus = model.heard.trimmingCharacters(in: .whitespaces).isEmpty ? .heard : .write
      return
    }
    if model.settleFields() { model.tableFocusRequest += 1 }
    else { DispatchQueue.main.async { focus = column } }
  }

  private func title(_ column: Column) -> String {
    switch (model.section, column) {
    case (.fillers, _): return "Filler"
    case (.examples, .heard): return "Said"
    case (.examples, .write): return "Expect"
    case (_, .heard): return "Heard as"
    case (_, .write): return "Write as"
    }
  }
  private func placeholder(_ column: Column) -> String {
    switch (model.section, column) {
    case (.fillers, _): return "e.g. ahhh"
    case (.examples, .heard): return "e.g. Um, open Kaluma with PN PM."
    case (.examples, .write): return "The text you want pasted"
    case (_, .heard): return "e.g. PN PM"
    case (_, .write): return "e.g. pnpm"
    }
  }

  private func rowLabel(_ entry: Entry) -> String {
    switch model.section {
    case .fillers: return "Remove \(entry.heard)"
    case .examples:
      return "\(entry.heard), expect \(entry.write), " + (model.exampleFailures[entry.heard] == nil ? "passes" : "fails")
    default: return "\(entry.heard), write \(entry.write)"
    }
  }

  private func chooseImport() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
    panel.message = "Choose a vocabulary JSON file: up to 5,000 entries and 1 MB. You review it before saving."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let handle = try FileHandle(forReadingFrom: url)
      defer { try? handle.close() }
      let data = try handle.read(upToCount: VocabularySheet.maximumBytes + 1) ?? Data()
      guard data.count <= VocabularySheet.maximumBytes else {
        throw VocabularySheet.Invalid.document("Choose a vocabulary JSON file smaller than 1 MB.")
      }
      model.importData(data)
    } catch { model.report(error) }
  }
  private func export() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "khuluma-vocabulary.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      try model.document.encoded().write(to: url, options: .atomic)
      model.failed = false; model.message = "Vocabulary exported."
    } catch { model.report(error) }
  }
}

/// Gives the table's NSTableView keyboard focus when `request` changes, so
/// arrow keys work straight after an edit ends. SwiftUI focus does not
/// reach the table itself.
private struct TableFocus: NSViewRepresentable {
  var request: Int

  final class Coordinator { var request = 0 }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSView {
    context.coordinator.request = request
    return NSView()
  }
  func updateNSView(_ view: NSView, context: Context) {
    guard context.coordinator.request != request else { return }
    context.coordinator.request = request
    // After SwiftUI has removed the edit field.
    DispatchQueue.main.async {
      guard let window = view.window, let root = window.contentView,
            let table = Self.table(in: root) else { return }
      window.makeFirstResponder(table)
    }
  }
  private static func table(in view: NSView) -> NSTableView? {
    if let table = view as? NSTableView { return table }
    for child in view.subviews { if let table = table(in: child) { return table } }
    return nil
  }
}

/// The native search field, with Command-F focusing it through `focusRequest`.
private struct SearchField: NSViewRepresentable {
  @Binding var text: String
  var focusRequest: Int

  func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
  func makeNSView(context: Context) -> NSSearchField {
    let field = NSSearchField()
    field.placeholderString = "Search"
    field.sendsSearchStringImmediately = true
    field.delegate = context.coordinator
    field.setAccessibilityLabel("Search vocabulary")
    field.toolTip = "Search vocabulary (⌘F)"
    context.coordinator.request = focusRequest
    return field
  }
  func updateNSView(_ field: NSSearchField, context: Context) {
    context.coordinator.text = $text
    if field.stringValue != text { field.stringValue = text }
    field.isEnabled = context.environment.isEnabled
    if context.coordinator.request != focusRequest {
      context.coordinator.request = focusRequest
      DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
    }
  }

  final class Coordinator: NSObject, NSSearchFieldDelegate {
    var text: Binding<String>
    var request = 0
    init(text: Binding<String>) { self.text = text }
    func controlTextDidChange(_ notification: Notification) {
      guard let field = notification.object as? NSSearchField else { return }
      text.wrappedValue = field.stringValue
    }
  }
}
