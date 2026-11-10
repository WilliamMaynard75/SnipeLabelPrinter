import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var dropTargeted = false
    @FocusState private var tagFieldFocused: Bool

    var body: some View {
        HSplitView {
            labelList
                .frame(minWidth: 320, idealWidth: 380)
            VStack(alignment: .leading, spacing: 16) {
                settings
                Divider()
                tapePreview
                Spacer()
                footer
            }
            .padding()
            .frame(minWidth: 420)
        }
        .frame(minWidth: 820, minHeight: 520)
    }

    private var labelList: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            if model.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "doc.badge.plus").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("Search for an asset above,").font(.headline)
                    Text("or drop Snipe-IT label PDFs here").font(.headline)
                    Button("Choose Files…") { model.chooseFiles() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(model.items) { item in
                        LabelRow(item: item) { model.remove(item) }
                    }
                }
            }
            HStack {
                Button("Add…") { model.chooseFiles() }
                Spacer()
                Button("Clear") { model.clear() }.disabled(model.items.isEmpty)
            }
            .padding(8)
        }
        .overlay(dropTargeted ? RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 3).padding(4) : nil)
        .dropDestination(for: URL.self) { urls, _ in
            model.add(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
        .onAppear { tagFieldFocused = true }
    }

    /// Search box plus, while typing, matching assets to click.
    private var searchBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Asset name or tag, or scan a label", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .focused($tagFieldFocused)
                    .onSubmit {
                        model.submitSearch()
                        tagFieldFocused = true
                    }
                    .onExitCommand { model.clearSearch() }
                if model.isSearching { ProgressView().controlSize(.small) }
            }
            if let message = model.searchMessage {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if !model.searchResults.isEmpty && !model.searchText.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.searchResults) { asset in
                            SearchResultRow(asset: asset) {
                                model.add(asset)
                                tagFieldFocused = true
                            }
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 220)
                .background(.background, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            }
        }
        .padding(8)
    }

    private var settings: some View {
        Form {
            Stepper("Copies of each: \(model.copies)", value: $model.copies, in: 1...50)
            HStack {
                Text("Gap between labels")
                Slider(value: $model.gapMM, in: 0...10, step: 0.5)
                Text("\(model.gapMM, specifier: "%.1f") mm").monospacedDigit().frame(width: 60, alignment: .trailing)
            }
            Toggle("Dashed cut line between labels", isOn: $model.cutMarks)
            HStack {
                Text("Blank tape at end")
                Slider(value: $model.endMarginMM, in: 0...30, step: 1)
                Text("\(model.endMarginMM, specifier: "%.0f") mm").monospacedDigit().frame(width: 60, alignment: .trailing)
            }
            .help("Matches the blank lead-in the printer feeds before the first label, so the label ends up centered.")
            HStack {
                Text("Black threshold")
                Slider(value: $model.options.threshold, in: 0.2...0.8, step: 0.05)
                Text("\(Int(model.options.threshold * 100))%").monospacedDigit().frame(width: 60, alignment: .trailing)
            }
            Stepper("Top/bottom margin: \(model.options.marginDots) dots", value: $model.options.marginDots, in: 0...16)
            Toggle("Trim white space", isOn: $model.options.trimWhitespace)
            Toggle("Turn portrait labels sideways", isOn: $model.options.autoRotate)
        }
    }

    private var tapePreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let job = model.job {
                Text("Tape preview: \(job.lengthMM, specifier: "%.0f") mm long").font(.headline)
                ScrollView(.horizontal) {
                    BitmapView(bitmap: job, scale: 2)
                        .border(Color.secondary.opacity(0.4))
                }
            } else {
                Text("Tape preview").font(.headline)
                Text("Add a label to see what will print.").foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            HStack {
                Image(systemName: "printer")
                Text(model.printerStatus).foregroundStyle(.secondary)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Check Printer") { model.checkPrinter() }.disabled(model.isBusy)
                Button("Save PNG…") { model.exportPNG() }.disabled(model.job == nil)
                Button("Print") { model.printJob() }
                    .keyboardShortcut("p")
                    .buttonStyle(.borderedProminent)
                    .disabled(model.job == nil || model.isBusy || model.isFetching)
            }
        }
    }
}

struct SearchResultRow: View {
    let asset: AssetSummary
    let onAdd: () -> Void

    var body: some View {
        Button(action: onAdd) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(asset.name.isEmpty ? asset.tag : asset.name).font(.body.weight(.medium))
                    Text([asset.tag, asset.model, asset.assignedTo].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "plus.circle.fill").foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Add this asset's label")
    }
}

struct LabelRow: View {
    let item: LabelItem
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.headline)
                if let bitmap = item.bitmap {
                    BitmapView(bitmap: bitmap, scale: 1)
                        .border(Color.secondary.opacity(0.4))
                    Text("\(bitmap.width) × \(bitmap.height) dots, \(bitmap.lengthMM, specifier: "%.0f") mm")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let error = item.error {
                    Text(error).foregroundStyle(.red)
                } else if item.isLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Fetching from Snipe-IT…").foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button(action: onRemove) { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// Shows a 1-bit bitmap with hard pixel edges, so the preview looks like the print.
struct BitmapView: View {
    let bitmap: MonoBitmap
    let scale: CGFloat

    var body: some View {
        if let image = bitmap.cgImage() {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .frame(width: CGFloat(bitmap.width) * scale, height: CGFloat(bitmap.height) * scale)
        }
    }
}
