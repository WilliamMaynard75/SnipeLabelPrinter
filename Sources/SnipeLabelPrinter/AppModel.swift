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

    /// Fetches labels from Snipe-IT. `text` holds asset tags or scanned QR links,
    /// separated by commas, spaces or new lines.
    func addTags(_ text: String) {
        let entries = text.split(whereSeparator: { ", ;\n\t".contains($0) }).map(String.init)
        guard !entries.isEmpty else { return }
        let client: SnipeITClient
        do { client = try SnipeITClient.fromSettings() } catch {
            lastError = error.localizedDescription
            return
        }
        lastError = nil
        for entry in entries {
            let placeholder = LabelItem(name: entry)
            items.append(placeholder)
            Task {
                do {
                    let (tag, pdf) = try await client.label(for: entry)
                    replace(placeholder.id, withPagesOf: pdf, name: tag)
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
