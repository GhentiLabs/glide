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
            .safeAreaInset(edge: .bottom) { PrivacyCard() }
        } detail: {
            switch section {
            case .home: HomeView()
            case .dictionary: DictionaryView()
            }
        }
        .frame(minWidth: 760, minHeight: 520)
        .tint(Tokens.tint)
    }
}

/// Bottom left of the sidebar, where an account will go. Until then it says where your data lives.
private struct PrivacyCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.laptopcomputer").font(.system(size: 17)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("On this Mac").font(.callout.weight(.medium))
                Text("Nothing is uploaded").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Settings", systemImage: "gearshape") { app.open("settings") }
                .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                Headline()
                if !app.store.records.isEmpty { Stats(records: app.store.records) }
                GettingStarted()
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("History").font(.title3.weight(.semibold))
                        Spacer()
                        SearchPill(query: $query)
                    }
                    if app.store.records.isEmpty {
                        ContentUnavailableView(
                            "No dictations yet", systemImage: "waveform",
                            description: Text("Hold fn in any app and speak. What you say shows up here."))
                            .frame(maxWidth: .infinity).card()
                    } else if groups.isEmpty {
                        ContentUnavailableView.search(text: query).frame(maxWidth: .infinity).card()
                    }
                    ForEach(groups, id: \.day) { group in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(Self.title(for: group.day)).font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
                            VStack(spacing: 0) {
                                ForEach(group.records) { record in
                                    HistoryRow(record: record)
                                    if record.id != group.records.last?.id { Divider().padding(.leading, 92) }
                                }
                            }
                            .card(padding: 6)
                        }
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: Tokens.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Tokens.canvas)
        .navigationTitle("Home")
    }

    private static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }
}

/// "Hold fn to dictate in Messages", or what stands in the way.
private struct Headline: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            if app.paused {
                Text("Glide is paused")
                Spacer()
                Button("Resume") { app.paused = false }.buttonStyle(.borderedProminent)
            } else if !app.hasAccessibility {
                Text("Glide needs Accessibility")
                Spacer()
                Button("Open Settings", action: app.guideAccessibility).buttonStyle(.borderedProminent)
            } else if let progress = app.modelProgress, !app.modelFailed {
                Text("Getting ready")
                ProgressView(value: progress).frame(width: 120)
                Text("\(Int(progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
            } else {
                Text("Hold")
                Keycap("fn", size: 20)
                if let lastApp = app.lastApp, let name = lastApp.localizedName {
                    Text("to dictate in")
                    if let icon = lastApp.icon { Image(nsImage: icon).resizable().frame(width: 28, height: 28) }
                    Text(name)
                } else {
                    Text("to dictate")
                }
                Spacer()
            }
        }
        .font(.system(size: 24, weight: .semibold, design: .rounded))
        .lineLimit(1)
        .animation(Tokens.spring, value: app.lastApp)
    }
}

private struct Stats: View {
    let records: [DictationRecord]

    var body: some View {
        let words = records.reduce(0) { $0 + ($1.finalText ?? $1.refinedText).split(whereSeparator: \.isWhitespace).count }
        // Typing at 40 words a minute against speaking at 150.
        let minutesSaved = Int((Double(words) / 40 - Double(words) / 150).rounded())
        let today = records.filter { Calendar.current.isDateInToday($0.time) }.count
        HStack(spacing: 0) {
            tile("Words dictated", value: words.formatted(), unit: "words")
            tile("Time saved", value: minutesSaved >= 60 ? "\(minutesSaved / 60) hr \(minutesSaved % 60)" : "\(minutesSaved)", unit: "min")
            tile("Today", value: today.formatted(), unit: today == 1 ? "dictation" : "dictations")
        }
        .card(padding: 18)
    }

    private func tile(_ title: String, value: String, unit: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(unit).font(.callout).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A few first tasks that tick themselves off; the row leaves once they're all done.
private struct GettingStarted: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let tasks: [(symbol: String, title: String, detail: String, done: Bool)] = [
            ("mic", "Your first dictation", "Hold fn anywhere and speak.", !app.store.records.isEmpty),
            ("hand.tap", "Go hands-free", "Double-tap fn, then tap it again to finish.", app.usedHandsFree),
            ("clipboard", "Paste the last one", "Press ⌃⌘V to paste your last dictation again.", app.usedPasteLast),
        ]
        if tasks.contains(where: { !$0.done }) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Getting started").font(.title3.weight(.semibold))
                HStack(alignment: .top, spacing: 12) {
                    ForEach(tasks, id: \.title) { task in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: task.symbol).foregroundStyle(task.done ? AnyShapeStyle(.tertiary) : AnyShapeStyle(Tokens.tint))
                                Spacer()
                                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(task.done ? AnyShapeStyle(Tokens.tint) : AnyShapeStyle(.tertiary))
                            }
                            .font(.title3)
                            .frame(height: 24)
                            Group {
                                Text(task.title).font(.headline)
                                Text(task.detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            .opacity(task.done ? 0.55 : 1)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .card(padding: 16)
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(task.done ? "Done" : "Not done")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .transition(.opacity)
        }
    }
}

private struct SearchPill: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query).textFieldStyle(.plain)
            if !query.isEmpty {
                Button("Clear", systemImage: "xmark.circle.fill") { query = "" }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .frame(width: 220)
        .background(Capsule().fill(.quaternary.opacity(0.6)))
    }
}

private struct HistoryRow: View {
    let record: DictationRecord
    @State private var hovering = false
    @State private var copied = false

    private var text: String { record.finalText ?? record.refinedText }

    private var app: (name: String, icon: NSImage)? {
        guard let id = record.app, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return nil }
        return (FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""), NSWorkspace.shared.icon(forFile: url.path))
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(record.time, format: .dateTime.hour().minute())
                .monospacedDigit().foregroundStyle(.secondary).fixedSize().frame(width: 64, alignment: .leading)
            Group {
                if let app {
                    Image(nsImage: app.icon).resizable().frame(width: 16, height: 16).help(app.name).accessibilityLabel(app.name)
                } else {
                    Color.clear.frame(width: 16, height: 16)
                }
            }
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            Text(text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc").contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .help("Copy")
            .accessibilityLabel(copied ? "Copied" : "Copy")
            .opacity(hovering || copied ? 1 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 9).fill(.quaternary.opacity(hovering ? 0.35 : 0)))
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
