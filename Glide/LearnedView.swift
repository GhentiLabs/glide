import AppKit
import Charts
import GlideCore
import SwiftUI

/// What Glide picked up from your fixes, from the result down to the evidence.
struct LearnedView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                EditRate(records: app.store.records)
                WordsSection()
                CorrectionsSection()
                AppsSection(records: app.store.records)
            }
            .padding(28)
            .frame(maxWidth: Tokens.contentWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Tokens.canvas)
        .navigationTitle("Learned")
    }
}

/// The share of followed dictations you fixed, by week. Falling is good.
private struct EditRate: View {
    let records: [DictationRecord]

    private struct Week: Identifiable {
        let start: Date
        let followed: Int
        let edited: Int
        var id: Date { start }
        var rate: Double { followed == 0 ? 0 : Double(edited) / Double(followed) }
    }

    private var weeks: [Week] {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        return (0..<8).reversed().compactMap { back in
            guard let start = calendar.date(byAdding: .weekOfYear, value: -back, to: thisWeek),
                let end = calendar.date(byAdding: .weekOfYear, value: 1, to: start)
            else { return nil }
            let inWeek = records.filter { $0.time >= start && $0.time < end && ($0.verdict == .edited || $0.verdict == .untouched) }
            return Week(start: start, followed: inWeek.count, edited: inWeek.filter { $0.verdict == .edited }.count)
        }
    }

    var body: some View {
        let weeks = weeks
        let now = weeks.last, before = weeks.dropLast().last
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Edit rate this week").font(.subheadline).foregroundStyle(.secondary)
                if let now, now.followed > 0 {
                    Text(now.rate, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
                    Text("\(now.edited) of \(now.followed) dictations fixed" + (before.map { $0.followed > 0 ? ". Last week \(Int(($0.rate * 100).rounded()))%." : "." } ?? "."))
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Nothing yet").font(.system(size: 26, weight: .semibold, design: .rounded))
                    Text("Dictate into any app and fix what Glide got wrong.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 0)
            if weeks.filter({ $0.followed > 0 }).count >= 2 {
                Chart(weeks.filter { $0.followed > 0 }) {
                    LineMark(x: .value("Week", $0.start), y: .value("Edit rate", $0.rate))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("Week", $0.start), y: .value("Edit rate", $0.rate)).symbolSize(16)
                }
                .foregroundStyle(Tokens.tintGraphic)
                .chartYAxis(.hidden).chartXAxis(.hidden)
                .chartYScale(domain: 0...1)
                .frame(width: 180, height: 52)
                .accessibilityLabel("Edit rate over the last eight weeks")
            }
        }
        .card(padding: 18)
    }
}

private struct WordsSection: View {
    @Environment(AppModel.self) private var app
    @State private var adding = false

    private var words: [DictionaryEntry] { app.store.dictionary.sorted { $0.added > $1.added } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Words").font(.title3.weight(.semibold))
                Spacer()
                Button("Add Word", systemImage: "plus") { adding = true }.buttonStyle(.borderless)
            }
            if words.isEmpty {
                Text("When you fix a name or a term Glide misheard, it shows up here and Glide listens for it from then on.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).card()
            } else {
                VStack(spacing: 0) {
                    ForEach(words) { word in
                        WordRow(entry: word)
                        if word.id != words.last?.id { Divider().padding(.leading, 12) }
                    }
                }
                .card(padding: 6)
            }
        }
        .sheet(isPresented: $adding) { AddWord { app.store.upsert(DictionaryEntry(word: $0)) } }
    }
}

private struct WordRow: View {
    let entry: DictionaryEntry
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(entry.word).fontWeight(.medium)
            Group {
                if entry.source == .user {
                    Text("added by you")
                } else if let heard = entry.heardAs.first {
                    Text("heard as \(heard)")
                }
            }
            .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Text(entry.added, format: .relative(presentation: .named)).font(.callout).foregroundStyle(.secondary)
            Button("Remove", systemImage: "minus.circle") { app.store.remove(entries: [entry.id]) }
                .labelStyle(.iconOnly).buttonStyle(.borderless).help("Remove \(entry.word)")
                .opacity(hovering ? 1 : 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

private struct AddWord: View {
    let save: (String) -> Void
    @State private var word = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            TextField("Word", text: $word, prompt: Text("kubectl"))
            Text("Glide listens for it and spells it this way when it hears it.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    save(word.trimmingCharacters(in: .whitespaces))
                    dismiss()
                }
                .disabled(word.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

private struct CorrectionsSection: View {
    @Environment(AppModel.self) private var app
    enum Filter: String, CaseIterable { case all = "All", used = "Used", notUsed = "Not Used" }
    @State private var filter = Filter.all

    private var corrections: [DictationRecord] {
        app.store.records.filter { !$0.diff.isEmpty }.filter {
            switch filter {
            case .all: true
            case .used: $0.teaches
            case .notUsed: !$0.teaches
            }
        }
    }

    var body: some View {
        let corrections = corrections
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Corrections").font(.title3.weight(.semibold))
                Spacer()
                Picker("Show", selection: $filter) {
                    ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            if corrections.isEmpty {
                Text(filter == .all ? "Fix a dictation in any app and it shows up here." : "Nothing here.")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).card()
            } else {
                VStack(spacing: 0) {
                    ForEach(corrections.prefix(100)) { record in
                        CorrectionRow(record: record)
                        if record.id != corrections.prefix(100).last?.id { Divider().padding(.leading, 12) }
                    }
                }
                .card(padding: 6)
            }
        }
    }
}

private struct CorrectionRow: View {
    let record: DictationRecord
    @Environment(AppModel.self) private var app
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(EditMarks.text(for: record)).textSelection(.enabled)
            HStack(spacing: 8) {
                Text(EditMarks.summary(for: record)).font(.system(.caption, design: .serif)).italic()
                if let name = record.appName { Text(name) }
                Text(record.time, format: .relative(presentation: .named))
                Spacer()
                Button(record.excluded == true ? "Use It" : "Not a Correction") { app.setExcluded(record.id, record.excluded != true) }
                    .buttonStyle(.borderless).opacity(hovering || record.excluded == true ? 1 : 0)
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

/// How often Glide could follow your edits in each app. Terminals and some web apps may not allow it.
private struct AppsSection: View {
    let records: [DictationRecord]
    @State private var expanded = false

    private var apps: [(id: String, name: String, followed: Int, total: Int)] {
        Dictionary(grouping: records.filter { $0.verdict != .pending && $0.skipReason != .learningOff }) { $0.app ?? "" }
            .map { id, group in
                (id, group[0].appName ?? "Unknown app", group.filter { $0.verdict == .edited || $0.verdict == .untouched }.count, group.count)
            }
            .sorted { $0.total > $1.total }
    }

    var body: some View {
        let apps = apps
        if !apps.isEmpty {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: 0) {
                    ForEach(apps, id: \.id) { app in
                        HStack {
                            Text(app.name)
                            Spacer()
                            Text("followed \(app.followed) of \(app.total)").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .accessibilityElement(children: .combine)
                    }
                }
                .card(padding: 6)
                .padding(.top, 10)
            } label: {
                Text("Apps").font(.title3.weight(.semibold))
            }
        }
    }
}

extension DictationRecord {
    /// True when at least one span trains something and the user hasn't ruled the record out.
    var teaches: Bool { excluded != true && diff.contains { $0.kind != .rewrite && $0.kind != .addition } }

    var appName: String? {
        guard let app, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Draws an edit on the text: removed words struck through, replacements dotted underneath, added words underlined.
enum EditMarks {
    static func text(for record: DictationRecord) -> AttributedString {
        guard let final = record.finalText, !record.diff.isEmpty else { return AttributedString(record.finalText ?? record.refinedText) }
        let pasted = record.refinedText.split(whereSeparator: \.isWhitespace).map(String.init)
        let kept = final.split(whereSeparator: \.isWhitespace).map(String.init)
        var out = AttributedString()
        var p = 0
        func add(_ words: ArraySlice<String>, _ style: (inout AttributedString) -> Void = { _ in }) {
            guard !words.isEmpty else { return }
            if !out.characters.isEmpty { out += AttributedString(" ") }  // unstyled, so marks start on the word
            var piece = AttributedString(words.joined(separator: " "))
            style(&piece)
            out += piece
        }
        for span in record.diff.sorted(by: { $0.pastedWords.lowerBound < $1.pastedWords.lowerBound })
        where span.pastedWords.upperBound <= pasted.count && span.finalWords.upperBound <= kept.count {
            add(pasted[p..<max(p, span.pastedWords.lowerBound)])
            let replaced = !span.pastedWords.isEmpty && !span.finalWords.isEmpty
            add(pasted[span.pastedWords]) {
                $0.swiftUI.strikethroughStyle = .single
                $0.swiftUI.foregroundColor = .secondary
            }
            add(kept[span.finalWords]) {
                $0.swiftUI.underlineStyle = replaced ? Text.LineStyle(pattern: .dot) : .single
                $0.swiftUI.foregroundColor = Tokens.tint
            }
            p = max(p, span.pastedWords.upperBound)
        }
        add(pasted[min(p, pasted.count)...])
        return out
    }

    /// "misheard · formatting", or "not used" when nothing in the edit trains anything.
    static func summary(for record: DictationRecord) -> String {
        guard record.teaches else { return "not used" }
        var seen: [EditSpan.Kind] = []
        for span in record.diff where span.kind != .rewrite && span.kind != .addition && !seen.contains(span.kind) { seen.append(span.kind) }
        return seen.map(\.rawValue).joined(separator: " · ")
    }
}
