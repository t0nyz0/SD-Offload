import SwiftUI
import OffloadCore

struct PhotoTagsSection: View {
    let entry: LibraryEntry
    let model: LibraryModel
    @State private var tags: [String] = []
    @State private var loading = true
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tags").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Edit Tags…") { editing = true }
                    .controlSize(.small)
                    .disabled(loading)
                    .help("Add, rename, or remove this photo’s searchable tags")
            }
            if loading {
                ProgressView().controlSize(.small)
            } else if tags.isEmpty {
                Text("No tags yet. Add your own with Edit Tags.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                FlowLayout(spacing: 5) {
                    ForEach(tags, id: \.self) { tag in
                        Text(tag)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.white.opacity(0.12), in: Capsule())
                    }
                }
            }
        }
        .task(id: model.tags(for: entry)) {
            let loaded = await model.allTags(for: entry)
            guard !Task.isCancelled else { return }
            tags = loaded
            loading = false
        }
        .sheet(isPresented: $editing) {
            PhotoTagsEditor(entry: entry, model: model, initialTags: tags) { tags = $0 }
        }
    }
}

private struct PhotoTagsEditor: View {
    let entry: LibraryEntry
    let model: LibraryModel
    let onSaved: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    init(entry: LibraryEntry, model: LibraryModel, initialTags: [String], onSaved: @escaping ([String]) -> Void) {
        self.entry = entry
        self.model = model
        self.onSaved = onSaved
        _text = State(initialValue: initialTags.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Edit Tags").font(.title2.bold())
            Text(entry.name).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            Text("One tag per line, or separate tags with commas. Change a tag to rename it; delete it to remove it.")
                .font(.callout)
            TextEditor(text: $text)
                .font(.body)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.secondary.opacity(0.3)))
                .frame(height: 180)
                .accessibilityLabel("Photo tags")
                .focused($focused)
                .disabled(saving)
            Text("Saved in SD Offload on this Mac, not embedded in the photo. Your edits are used in search and kept when AI analyzes the photo again.")
                .font(.caption).foregroundStyle(.secondary)
            if let error {
                Text("Couldn’t save tags: \(error)")
                    .font(.callout).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction).disabled(saving)
                Button("Save Tags") { save() }
                    .keyboardShortcut(.defaultAction).disabled(saving)
            }
        }
        .padding(24)
        .frame(width: 430)
        .interactiveDismissDisabled(saving)
        .onAppear { focused = true }
    }

    private func save() {
        saving = true
        error = nil
        let values = text.components(separatedBy: CharacterSet(charactersIn: ",\n\r"))
        Task {
            do {
                let saved = try await model.saveTags(values, for: entry)
                onSaved(saved)
                dismiss()
            } catch {
                self.error = error.localizedDescription
                saving = false
            }
        }
    }
}
