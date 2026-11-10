import AppKit
import Foundation

struct LabelItem: Identifiable {
    let id = UUID()
    let url: URL
    var bitmap: MonoBitmap?
    var error: String?

    var name: String { url.deletingPathExtension().lastPathComponent }
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

    /// Everything that will go to the printer, chained into one job so the leader tape is only fed once.
    var job: MonoBitmap? {
        let labels = items.compactMap(\.bitmap)
        let all = Array(repeating: labels, count: max(copies, 1)).flatMap { $0 }
        return MonoBitmap.chain(all, gap: MonoBitmap.dots(mm: gapMM), cutMarks: cutMarks)?
            .padded(trailing: MonoBitmap.dots(mm: endMarginMM))
    }

    func add(_ urls: [URL]) {
        for url in urls where url.pathExtension.lowercased() == "pdf" {
            var item = LabelItem(url: url)
            render(&item)
            items.append(item)
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
        do {
            item.bitmap = try LabelRenderer.render(pdf: item.url, options: options)
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
