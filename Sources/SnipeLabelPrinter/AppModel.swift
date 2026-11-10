import AppKit
import Foundation

struct LabelItem: Identifiable {
    let id = UUID()
    var name: String
    /// Nil while the label is still being fetched from Snipe-IT.
    var pdf: Data?
    var page = 1
    var bitmap: MonoBitmap?
    var error: String?

    var isLoading: Bool { pdf == nil && error == nil }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var items: [LabelItem] = []
    @Published var options = RenderOptions() { didSet { if options != oldValue { rerenderAll() } } }
    @Published var copies = 1
    @Published var gapMM = 2.0
    @Published var cutMarks = true
    /// Blank tape added after the last label to match the printer's fixed lead-in, so the content
    /// sits centered on the cut piece (Brother's Windows software does the same).
    @Published var endMarginMM = 20.0
    @Published var printerStatus = "Printer not checked yet"
    @Published var isBusy = false
    @Published var lastError: String?

    /// The asset search box. Typing searches Snipe-IT after a short pause.
    @Published var searchText = "" { didSet { if searchText != oldValue { scheduleSearch() } } }
    @Published var searchResults: [AssetSummary] = []
    @Published var searchMessage: String?
    @Published var isSearching = false
    private var searchTask: Task<Void, Never>?

    var isFetching: Bool { items.contains(where: \.isLoading) }

    /// Everything that will go to the printer, chained into one job so the leader tape is only fed once.
    var job: MonoBitmap? {
        let labels = items.compactMap(\.bitmap)
        let all = Array(repeating: labels, count: max(copies, 1)).flatMap { $0 }
        return MonoBitmap.chain(all, gap: MonoBitmap.dots(mm: gapMM), cutMarks: cutMarks)?
            .padded(trailing: MonoBitmap.dots(mm: endMarginMM))
    }

    /// Adds PDF files, one item per page (Snipe-IT puts one label on each page).
    func add(_ urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            let name = url.deletingPathExtension().lastPathComponent
            guard let pdf = try? Data(contentsOf: url) else {
                items.append(LabelItem(name: name, error: "Couldn't read the file."))
                continue
            }
            items.append(contentsOf: pages(of: pdf, name: name))
        }
    }

    /// Return in the search box. A single entry with several matches shows them to pick from;
    /// anything clear-cut (exact tag or name, one match, a scanned QR link, a comma list) is fetched right away.
    func submitSearch() {
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if Self.isDirectEntry(text) {
            clearSearch()
            fetch(text)
            return
        }
        searchTask?.cancel()
        searchTask = Task {
            guard let results = await runSearch(text) else { return }
            if let match = SnipeITClient.pick(text, from: results) {
                add(match)
            } else if results.isEmpty {
                clearSearch()
                fetch(text)  // Lets the label lookup report "not found" in the list.
            } else {
                searchMessage = "\(results.count) matches. Pick one below."
            }
        }
    }

    /// Fetches the label for a search result.
    func add(_ asset: AssetSummary) {
        clearSearch()
        fetch(asset.tag, title: asset.name.isEmpty ? asset.tag : "\(asset.name) · \(asset.tag)")
    }

    func clearSearch() {
        searchTask?.cancel()
        searchText = ""
        searchResults = []
        searchMessage = nil
        isSearching = false
    }

    /// Comma-separated lists and scanned QR links skip the search list.
    private static func isDirectEntry(_ text: String) -> Bool {
        text.contains("://") || text.contains(where: { ",;\n\t".contains($0) })
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= 2, !Self.isDirectEntry(text) else {
            searchResults = []
            searchMessage = nil
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            _ = await runSearch(text)
        }
    }

    /// Searches Snipe-IT and publishes the results; nil if cancelled or failed.
    private func runSearch(_ text: String) async -> [AssetSummary]? {
        isSearching = true
        // A cancelled search leaves the spinner to the search that replaced it.
        defer { if !Task.isCancelled { isSearching = false } }
        do {
            let results = try await SnipeITClient.fromSettings().search(text)
            guard !Task.isCancelled else { return nil }
            searchResults = results
            searchMessage = results.isEmpty ? "No assets match \u{201C}\(text)\u{201D}." : nil
            return results
        } catch {
            if !Task.isCancelled { searchMessage = error.localizedDescription }
            return nil
        }
    }

    /// Fetches labels from Snipe-IT. `text` holds asset tags, names or scanned QR links,
    /// separated by commas, semicolons or new lines.
    private func fetch(_ text: String, title: String? = nil) {
        let entries = text.split(whereSeparator: { ",;\n\t".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else { return }
        let client: SnipeITClient
        do { client = try SnipeITClient.fromSettings() } catch {
            lastError = error.localizedDescription
            return
        }
        lastError = nil
        for entry in entries {
            let placeholder = LabelItem(name: title ?? entry)
            items.append(placeholder)
            Task {
                do {
                    let (tag, pdf) = try await client.label(for: entry)
                    replace(placeholder.id, withPagesOf: pdf, name: title ?? tag)
                } catch {
                    if let i = items.firstIndex(where: { $0.id == placeholder.id }) {
                        items[i].error = error.localizedDescription
                    }
                }
            }
        }
    }

    private func replace(_ id: UUID, withPagesOf pdf: Data, name: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items.replaceSubrange(i...i, with: pages(of: pdf, name: name))
    }

    private func pages(of pdf: Data, name: String) -> [LabelItem] {
        let count = LabelRenderer.pageCount(of: pdf)
        guard count > 0 else { return [LabelItem(name: name, pdf: pdf, error: RenderError.unreadablePDF.localizedDescription)] }
        return (1...count).map { page in
            var item = LabelItem(name: count > 1 ? "\(name) (\(page) of \(count))" : name, pdf: pdf, page: page)
            render(&item)
            return item
        }
    }

    func remove(_ item: LabelItem) {
        items.removeAll { $0.id == item.id }
    }

    func clear() {
        items.removeAll()
    }

    private func rerenderAll() {
        for i in items.indices { render(&items[i]) }
    }

    private func render(_ item: inout LabelItem) {
        guard let pdf = item.pdf else { return }
        do {
            item.bitmap = try LabelRenderer.render(pdf: pdf, page: item.page, options: options)
            item.error = nil
        } catch {
            item.bitmap = nil
            item.error = error.localizedDescription
        }
    }

    func checkPrinter() {
        run { printer in
            let status = try printer.status()
            return status
        } done: { status in
            self.printerStatus = status.summary
            if let dots = status.tapeDots, dots != self.options.tapeDots {
                self.options.tapeDots = dots
            }
        }
    }

    func printJob() {
        guard let job else { return }
        run { printer in
            try printer.print(job)
            return try printer.status()
        } done: { status in
            self.printerStatus = "Sent \(String(format: "%.0f", job.lengthMM)) mm. \(status.summary)"
        }
    }

    /// Runs USB work off the main thread, then reports back on it.
    private func run<T>(_ work: @escaping (PTouchPrinter) throws -> T, done: @escaping (T) -> Void) {
        guard !isBusy else { return }
        isBusy = true
        lastError = nil
        Task.detached {
            let result = Result { try PTouchPrinter.withPrinter(work) }
            await MainActor.run {
                self.isBusy = false
                switch result {
                case let .success(value): done(value)
                case let .failure(error):
                    self.lastError = error.localizedDescription
                    self.printerStatus = "Not ready"
                }
            }
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { add(panel.urls) }
    }

    func exportPNG() {
        guard let job else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "label.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try job.writePNG(to: url) } catch { lastError = error.localizedDescription }
    }
}
