import AppKit
import GlideCore
import SwiftUI

struct MainWindow: View {
    enum Section: Hashable { case home, dictionary }

    @State private var section: Section = .home

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Label("Home", systemImage: "house").tag(Section.home)
                Label("Dictionary", systemImage: "book.closed").tag(Section.dictionary)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .safeAreaInset(edge: .bottom) { AccountButton() }
        } detail: {
            switch section {
            case .home: HomeView()
            case .dictionary: DictionaryView()
            }
        }
        .frame(minWidth: 720, minHeight: 460)
        .tint(Tokens.tint)
    }
}

/// Bottom left of the sidebar. Accounts don't exist yet; the popover says so.
private struct AccountButton: View {
    @Environment(AppModel.self) private var app
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 9) {
                Image(systemName: "person.crop.circle.fill").font(.system(size: 24)).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Local profile").font(.callout.weight(.medium))
                    Text("On this Mac").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(8)
        .popover(isPresented: $showing, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Accounts aren't available yet").font(.headline)
                Text("Glide keeps your history and dictionary on this Mac.").foregroundStyle(.secondary)
                Button("Open Settings") {
                    showing = false
                    app.open("settings")
                }
                .padding(.top, 4)
            }
            .padding(16)
            .frame(width: 270, alignment: .leading)
        }
    }
}

struct HomeView: View {
    @Environment(AppModel.self) private var app
    @State private var query = ""

    private var groups: [(day: Date, records: [DictationRecord])] {
        let matching = query.isEmpty ? app.store.records : app.store.records.filter {
            ($0.finalText ?? $0.refinedText).localizedCaseInsensitiveContains(query)
        }
        let calendar = Calendar.current
        var result: [(day: Date, records: [DictationRecord])] = []
        for record in matching {
            let day = calendar.startOfDay(for: record.time)
            if result.last?.day == day { result[result.count - 1].records.append(record) } else { result.append((day, [record])) }
        }
        return result
    }

    var body: some View {
        let groups = groups
        List {
            ForEach(groups, id: \.day) { group in
                Section(Self.title(for: group.day)) {
                    ForEach(group.records) { HistoryRow(record: $0) }
                }
            }
        }
        .overlay {
            if app.store.records.isEmpty {
                ContentUnavailableView(
                    "No dictations yet", systemImage: "waveform",
                    description: Text("Hold fn in any app and speak. What you say shows up here."))
            } else if groups.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, placement: .toolbar)
        .navigationTitle("Home")
    }

    private static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    @State private var hovering = false
    @State private var copied = false

    private var text: String { record.finalText ?? record.refinedText }

    private var appName: String? {
        guard let id = record.app, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(record.time, format: .dateTime.hour().minute())
                .monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                Text(text).textSelection(.enabled)
                if let appName { Text(appName).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .accessibilityLabel("Copy")
            .opacity(hovering || copied ? 1 : 0)
        }
        .padding(.vertical, 4)
        .onHover { hovering = $0 }
    }
}

struct DictionaryView: View {
    @Environment(AppModel.self) private var app
    @State private var selection = Set<UUID>()
    @State private var editing: DictionaryEntry?
    @State private var query = ""

    private var entries: [DictionaryEntry] {
        let all = app.store.dictionary.sorted { $0.word.localizedCaseInsensitiveCompare($1.word) == .orderedAscending }
        return query.isEmpty ? all : all.filter {
            $0.word.localizedCaseInsensitiveContains(query) || $0.heardAs.contains { $0.localizedCaseInsensitiveContains(query) }
        }
    }

    var body: some View {
        Table(entries, selection: $selection) {
            TableColumn("Word", value: \.word)
            TableColumn("Heard as") { Text($0.heardAs.joined(separator: ", ")).foregroundStyle(.secondary) }
            TableColumn("From") { Text($0.source == .user ? "Added by you" : "Learned").foregroundStyle(.secondary) }
                .width(min: 90, ideal: 110)
            TableColumn("Used") { Text("\($0.uses)").monospacedDigit() }.width(min: 40, ideal: 50)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("Edit…") { editing = app.store.dictionary.first { $0.id == ids.first } }.disabled(ids.count != 1)
            Button("Delete", role: .destructive) { app.store.remove(entries: ids) }
        } primaryAction: { ids in
            editing = app.store.dictionary.first { $0.id == ids.first }
        }
        .onDeleteCommand { app.store.remove(entries: selection) }
        .overlay {
            if app.store.dictionary.isEmpty {
                ContentUnavailableView {
                    Label("No words yet", systemImage: "book.closed")
                } description: {
                    Text("Add names and terms Glide should spell your way.")
                } actions: {
                    Button("Add Word") { editing = DictionaryEntry(word: "") }
                }
            }
        }
        .searchable(text: $query, placement: .toolbar)
        .toolbar {
            Button("Add Word", systemImage: "plus") { editing = DictionaryEntry(word: "") }
        }
        .sheet(item: $editing) { entry in
            EntryEditor(entry: entry) { app.store.upsert($0) }
        }
        .navigationTitle("Dictionary")
    }
}

private struct EntryEditor: View {
    @State var entry: DictionaryEntry
    let save: (DictionaryEntry) -> Void
    @State private var heardAs = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Word", text: $entry.word, prompt: Text("kubectl"))
            TextField("Heard as", text: $heardAs, prompt: Text("cube control, cube cuttle"))
            Text("Separate each way Glide mishears it with a comma. Glide replaces them with the word.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 400)
        .onAppear { heardAs = entry.heardAs.joined(separator: ", ") }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    entry.word = entry.word.trimmingCharacters(in: .whitespaces)
                    entry.heardAs = heardAs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    save(entry)
                    dismiss()
                }
                .disabled(entry.word.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
