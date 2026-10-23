import AppKit
import KhulumaCore
import SwiftUI
import UniformTypeIdentifiers

struct VocabularyView: View {
  @ObservedObject var settings: SettingsModel
  @StateObject private var model: VocabularyModel
  @Environment(\.dismiss) private var dismiss
  init(settings: SettingsModel) {
    self.settings = settings
    _model = StateObject(wrappedValue: VocabularyModel(settings: settings))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Vocabulary").font(.title2.weight(.semibold))
          Text("Fillers, brands and preferred spellings in one place.")
            .font(.callout).foregroundStyle(.secondary)
        }
        Spacer()
        if model.working { ProgressView().controlSize(.small).accessibilityLabel("Updating vocabulary") }
      }
      Picker("Section", selection: Binding(get: { model.section }, set: { model.changeSection($0) })) {
        ForEach(VocabularyModel.Section.allCases) { Text($0.rawValue).tag($0) }
      }
      .pickerStyle(.segmented).disabled(!model.canEdit || model.formDirty)
      HStack {
        TextField("Search vocabulary", text: $model.query)
          .textFieldStyle(.roundedBorder).accessibilityLabel("Search vocabulary")
        if !model.query.isEmpty {
          Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
            .buttonStyle(.plain).help("Clear search").accessibilityLabel("Clear search")
        }
      }
      .disabled(model.working || model.formDirty)
      HStack {
        Text(model.section == .fillers ? "Remove when heard" : "Heard as")
        Spacer()
        if model.section != .fillers { Text("Write as") }
      }
      .font(.caption).foregroundStyle(.secondary)

      List(selection: Binding(get: { model.selected }, set: { model.select($0) })) {
        ForEach(model.filtered) { entry in
          HStack {
            Text(entry.heard).lineLimit(2)
            if model.section != .fillers {
              Spacer(minLength: 16)
              Text(entry.write).foregroundStyle(.secondary).lineLimit(2)
            }
          }
          .padding(.vertical, 2).tag(entry.id)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(model.section == .fillers ? "Remove \(entry.heard)" : "\(entry.heard), write \(entry.write)")
        }
      }
      .listStyle(.bordered(alternatesRowBackgrounds: true))
      .frame(minHeight: 120)
      .overlay {
        if model.loaded && model.filtered.isEmpty {
          Text(model.query.isEmpty ? "No entries in this section. Add one below." : "No matching entries. Clear the search to see everything.")
            .font(.callout).foregroundStyle(.secondary).padding().allowsHitTesting(false)
        }
      }
      .disabled(!model.canEdit || model.formDirty)
      HStack {
        Text("\(model.filtered.count.formatted()) of \(model.entries.count.formatted()) \(model.entries.count == 1 ? "entry" : "entries")")
          .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Undo") { model.undo() }.disabled(!model.canEdit || model.undoStack.isEmpty || model.formDirty)
      }

      VStack(alignment: .leading, spacing: 8) {
        HStack(alignment: .top) {
          VStack(alignment: .leading, spacing: 4) {
            Text(model.section == .fillers ? "Filler or phrase" : "Heard as").font(.caption)
            TextField(model.section == .fillers ? "e.g. ahhh" : "e.g. PN PM", text: $model.heard)
              .accessibilityLabel(model.section == .fillers ? "Filler or phrase" : "Heard as")
          }
          if model.section != .fillers {
            VStack(alignment: .leading, spacing: 4) {
              Text("Write as").font(.caption)
              TextField("e.g. pnpm", text: $model.write).accessibilityLabel("Write as")
            }
          }
        }
        .textFieldStyle(.roundedBorder)
        .onSubmit { model.addOrUpdate() }
        HStack {
          Button(model.selected == nil ? "Add Entry" : "Update Entry") { model.addOrUpdate() }
            .disabled(model.heard.trimmingCharacters(in: .whitespaces).isEmpty || (model.section != .fillers && model.write.trimmingCharacters(in: .whitespaces).isEmpty))
          Button("Clear Fields") { model.clearFields() }.disabled(model.heard.isEmpty && model.write.isEmpty)
          Spacer()
          Button("Remove", role: .destructive) { model.remove() }.disabled(model.selected == nil || model.formDirty)
        }
        Text(model.formDirty ? "Add or update this entry, or clear the fields, before choosing another." :
          (model.section == .fillers ? "Literal phrases, ignoring case. Quoted words and filenames are preserved." : "Use one heard spelling per entry. Add another entry for each variation."))
          .font(.caption).foregroundStyle(.secondary).frame(minHeight: 28, alignment: .topLeading)
      }
      .disabled(!model.canEdit)
      Divider()
      if settings.recording {
        Label("Editing resumes when dictation finishes.", systemImage: "mic.fill").font(.caption)
      }
      VStack(alignment: .leading, spacing: 3) {
        if let message = model.message {
          Label(message, systemImage: model.failed ? "exclamationmark.triangle" : "checkmark.circle")
            .font(.caption).foregroundStyle(model.failed ? Color.primary : Color.secondary)
            .textSelection(.enabled).accessibilityLabel(message)
        } else {
          Text(model.dirty ? "Unsaved changes" : "JSON · Up to 5,000 entries · 1 MB maximum")
            .font(.caption).foregroundStyle(.secondary)
        }
      }.frame(minHeight: 30, alignment: .topLeading)
      HStack {
        Button("Import…") { chooseImport() }.disabled(!model.canEdit || model.formDirty)
        Button(model.dirty ? "Export Draft…" : "Export…") { export() }.disabled(!model.loaded || model.working || model.formDirty)
        Button("Reload") {
          if model.dirty || model.formDirty { model.confirmReload = true } else { model.load() }
        }.disabled(model.working)
        Spacer()
        Button(model.dirty || model.formDirty ? "Cancel" : "Done") { close() }.disabled(model.working)
        Button("Save Changes") { model.save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canEdit || !model.dirty || model.formDirty)
      }
      .controlSize(.small)
    }
    .padding(20).frame(width: 560, height: 660)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear { if !model.loaded { model.load() } }
    .interactiveDismissDisabled(model.dirty || model.formDirty || model.working)
    .onExitCommand { close() }
    .confirmationDialog("Discard vocabulary changes?", isPresented: $model.confirmDiscard) {
      Button("Discard Changes", role: .destructive) { dismiss() }
      Button("Keep Editing", role: .cancel) {}
    } message: { Text("Your saved vocabulary will stay as it is.") }
    .confirmationDialog("Reload saved vocabulary?", isPresented: $model.confirmReload) {
      Button("Reload and Discard Draft", role: .destructive) { model.load() }
      Button("Keep Editing", role: .cancel) {}
    } message: { Text("This discards unsaved entries and reads the latest vocabulary from disk.") }
    .confirmationDialog("Use imported vocabulary?", isPresented: Binding(
      get: { model.imported != nil }, set: { if !$0 { model.imported = nil } })) {
        Button("Use Imported Vocabulary") { model.useImport() }
        Button("Cancel", role: .cancel) { model.imported = nil }
      } message: { Text(model.importSummary) }
  }

  private func close() {
    guard !model.working else { return }
    if model.dirty || model.formDirty { model.confirmDiscard = true } else { dismiss() }
  }
  private func chooseImport() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
    panel.message = "Choose a vocabulary JSON file. Review it before saving."
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
