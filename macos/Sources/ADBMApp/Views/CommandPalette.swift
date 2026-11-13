// ⌘K palette: the same entries as v0.1 (each account, each loaded
// database, and Settings).
import ADBMCore
import SwiftUI

struct PaletteEntry: Identifiable {
    let id: String
    let group: String
    let label: String
    let sublabel: String?
    let action: @MainActor () -> Void
}

struct CommandPalette: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var entries: [PaletteEntry] {
        var list: [PaletteEntry] = (model.accounts ?? []).map { a in
            PaletteEntry(id: "acct-\(a.id)", group: "Account", label: a.name, sublabel: Fmt.regions(a.regions)) {
                model.go(accountId: a.id, tab: .overview)
            }
        }
        for a in model.accounts ?? [] {
            for db in model.databasesByAccount[a.id] ?? [] {
                list.append(PaletteEntry(id: "db-\(db.identifier)", group: "Database", label: db.identifier,
                                         sublabel: "\(Fmt.engine(db.engine)) · \(db.region)") {
                    model.go(accountId: a.id, tab: .backupPlans, focus: db.identifier)
                })
            }
        }
        list.append(PaletteEntry(id: "settings", group: "App", label: "Settings — manage AWS accounts", sublabel: nil) {
            model.select(.settings)
        })
        return list
    }

    private var filtered: [PaletteEntry] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { ($0.label + " " + ($0.sublabel ?? "")).lowercased().contains(q) }
    }

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Jump to an account or database…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { choose(items) }
                    .onChange(of: query) { index = 0 }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 2) {
                        if items.isEmpty {
                            Text("No matches").foregroundStyle(.secondary).padding()
                        }
                        ForEach(Array(items.enumerated()), id: \.element.id) { i, e in
                            Button { index = i; choose(items) } label: {
                                HStack(spacing: 10) {
                                    Text(e.group.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                        .frame(width: 70, alignment: .leading)
                                    Text(e.label)
                                    Spacer()
                                    if let s = e.sublabel { Text(s).font(.caption).foregroundStyle(.secondary) }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
                                .background(i == index ? Color.accentColor.opacity(0.22) : .clear, in: .rect(cornerRadius: 6))
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .id(i)
                            .onHover { if $0 { index = i } }
                        }
                    }
                    .padding(6)
                }
                .onChange(of: index) { _, i in proxy.scrollTo(i) }
            }
            .frame(height: 320)
        }
        .frame(width: 560)
        .onAppear { focused = true }
        .onKeyPress(.downArrow) { index = min(index + 1, max(items.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
        .onKeyPress(.escape) { dismiss(); return .handled }
    }

    private func choose(_ items: [PaletteEntry]) {
        guard items.indices.contains(index) else { return }
        let e = items[index]
        dismiss()
        e.action()
    }
}
