import AppKit
import KhulumaCore
import SwiftUI
import UniformTypeIdentifiers

/// The Vocabulary tab. The window owns the model, so a draft survives
/// switching tabs until it is saved or reloaded.
struct VocabularyView: View {
  @ObservedObject var model: VocabularyModel
  @ObservedObject var settings: SettingsModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Picker("Section", selection: Binding(get: { model.section }, set: { model.changeSection($0) })) {
          ForEach(VocabularyModel.Section.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented).labelsHidden().disabled(!model.canEdit || model.formDirty)
        if model.working { ProgressView().controlSize(.small).accessibilityLabel("Updating vocabulary") }
      }
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
        Text(model.section == .fillers ? "Remove when heard" : heardTitle)
        Spacer()
        if model.section != .fillers { Text(writeTitle) }
      }
      .font(.caption).foregroundStyle(.secondary)

      List(selection: Binding(get: { model.selected }, set: { model.select($0) })) {
        ForEach(model.filtered) { entry in
          HStack {
            if model.section == .examples {
              let got = model.exampleFailures[entry.heard]
              Image(systemName: got == nil ? "checkmark.circle" : "xmark.circle.fill")
                .foregroundStyle(got == nil ? Color.secondary : Color.red)
                .help(got.map { "Now gives: \($0.isEmpty ? "no speech" : $0)" } ?? "Passes with this draft")
            }
            Text(entry.heard).lineLimit(2)
            if model.section != .fillers {
              Spacer(minLength: 16)
              Text(entry.write).foregroundStyle(.secondary).lineLimit(2)
            }
          }
          .padding(.vertical, 2).tag(entry.id)
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(rowLabel(entry))
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
            HStack {
              Text(model.section == .fillers ? "Filler or phrase" : heardTitle).font(.caption)
              if model.section == .examples && !model.recent.isEmpty {
                Spacer()
                Menu("Recent") {
                  ForEach(model.recent, id: \.self) { text in
                    Button(String(text.prefix(80)) + (text.count > 80 ? "…" : "")) { model.heard = text }
                  }
                }
                .menuStyle(.borderlessButton).fixedSize().font(.caption)
                .help("Use a recent dictation (after filler and repetition cleanup, before vocabulary).")
              }
            }
            TextField(heardPlaceholder, text: $model.heard)
              .accessibilityLabel(model.section == .fillers ? "Filler or phrase" : heardTitle)
          }
          if model.section != .fillers {
            VStack(alignment: .leading, spacing: 4) {
              Text(writeTitle).font(.caption)
              TextField(model.section == .examples ? "The text you want pasted" : "e.g. pnpm", text: $model.write)
                .accessibilityLabel(writeTitle)
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
        if model.section == .examples {
          examplesHelp.font(.caption).frame(minHeight: 28, alignment: .topLeading)
        } else {
          Text(model.formDirty ? "Add or update this entry, or clear the fields, before choosing another." :
            (model.section == .fillers ? "Literal phrases, ignoring case. Quoted words and filenames are preserved." : "Use one heard spelling per entry. Add another entry for each variation."))
            .font(.caption).foregroundStyle(.secondary).frame(minHeight: 28, alignment: .topLeading)
        }
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
        Button("Save Changes") { model.save() }
          .keyboardShortcut(.defaultAction)
          .disabled(!model.canEdit || !model.dirty || model.formDirty)
      }
      .controlSize(.small)
    }
    .padding(.horizontal, 20).padding(.vertical, 14)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: .windowBackgroundColor))
    .onAppear { if !model.loaded { model.load() } }
    .confirmationDialog("Reload saved vocabulary?", isPresented: $model.confirmReload) {
      Button("Reload and Discard Draft", role: .destructive) { model.load() }
      Button("Keep Editing", role: .cancel) {}
    } message: { Text("This discards unsaved entries and reads the latest vocabulary from disk.") }
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

  private var heardTitle: String { model.section == .examples ? "Said" : "Heard as" }
  private var writeTitle: String { model.section == .examples ? "Expect" : "Write as" }
  private var heardPlaceholder: String {
    switch model.section {
    case .fillers: return "e.g. ahhh"
    case .examples: return "e.g. Um, open Kaluma with PN PM."
    default: return "e.g. PN PM"
    }
  }

  private func rowLabel(_ entry: VocabularyModel.Entry) -> String {
    switch model.section {
    case .fillers: return "Remove \(entry.heard)"
    case .examples:
      return "\(entry.heard), expect \(entry.write), " + (model.exampleFailures[entry.heard] == nil ? "passes" : "fails")
    default: return "\(entry.heard), write \(entry.write)"
    }
  }

  /// Examples: what the draft does to the Said text, or a fix for the
  /// selected failing example.
  @ViewBuilder private var examplesHelp: some View {
    if !model.formDirty, let rule = model.suggestedRule {
      HStack(spacing: 6) {
        Text("Fails. Add “\(rule.heard)” → “\(rule.write)”?").foregroundStyle(.secondary).lineLimit(1)
        Spacer(minLength: 4)
        Button("Add Rule") { model.addRule(rule) }.controlSize(.small)
      }
    } else if let preview = model.preview {
      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(preview.text.isEmpty ? "Gives no speech." : "Gives: \(preview.text)")
          .foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
          .help(preview.changes.map { "\($0.before.isEmpty ? "+" : $0.before) → \($0.after.isEmpty ? "removed" : $0.after)" }
            .joined(separator: "\n"))
        Spacer(minLength: 4)
        if model.write != preview.text {
          Button("Use as Expected") { model.write = preview.text }.controlSize(.small)
        }
      }
    } else {
      Text("Examples are checked against your vocabulary before every save. Cleanup never uses them as rules.")
        .foregroundStyle(.secondary)
    }
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
