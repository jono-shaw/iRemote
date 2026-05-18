import AppKit

/// Window that lists every Whisper model the user could be using and
/// lets them switch the active model, delete unwanted ones, or
/// download a fresh one from the catalog.
///
/// v42 rewrite — UX simplification per user feedback. The earlier
/// design had a separate "Status" *text* column ("Active" /
/// "Installed" / "Available") plus a button strip at the bottom for
/// Download / Delete. The user pointed out that's redundant: the
/// per-row state is finite enough that direct icon actions in the
/// Status column communicate it better and remove the need for the
/// button strip entirely.
///
/// Current row anatomy:
///
///   [✓?] Display name              Size       [↓ or 🗑]
///        filename · summary
///
/// - Left icon: a single accent-coloured `checkmark.circle.fill`
///   appears only on the active row (same convention as the macOS
///   Settings sidebar). Non-active rows leave the icon slot empty,
///   keeping the text left-aligned consistently.
/// - Status column: a click-targetable icon button. Cloud-with-arrow
///   for catalog rows that can be downloaded; trash for installed
///   non-active rows. The active row's status cell is empty (it
///   can't be deleted from here — the user must `Use Selected` on a
///   different model first).
/// - Bottom row: `Refresh` (secondary, left) and `Use Selected`
///   (primary, default, right). `Cancel Download` appears only
///   while a download is running.
///
/// Rows hidden entirely: catalog entries with no `downloadURL`
/// (currently none in the bundled catalog, but the filter is here
/// so the UI never shows a model that can't be either downloaded or
/// already-installed-deleted — no dead "unavailable" rows).
@MainActor
final class ModelManagerWindowController: NSWindowController, NSWindowDelegate {

    private struct Row {
        enum Source {
            case catalogOnly(WhisperModelInfo)
            case installedKnown(WhisperModelInfo, InstalledWhisperModel)
            case installedCustom(InstalledWhisperModel)
        }
        let source: Source
        let isActive: Bool

        var filename: String {
            switch source {
            case .catalogOnly(let info):      return info.filename
            case .installedKnown(let info, _): return info.filename
            case .installedCustom(let m):     return m.filename
            }
        }

        var displayName: String {
            switch source {
            case .catalogOnly(let info), .installedKnown(let info, _):
                return info.displayName
            case .installedCustom(let m):
                return m.filename
            }
        }

        var summary: String {
            switch source {
            case .catalogOnly(let info), .installedKnown(let info, _):
                return info.summary
            case .installedCustom:
                return "User-installed (not in catalog)"
            }
        }

        var sizeLabel: String {
            switch source {
            case .catalogOnly(let info):
                return "~\(info.approxSizeMB) MB"
            case .installedKnown(_, let m), .installedCustom(let m):
                return WhisperModelStore.formatBytes(m.sizeBytes)
            }
        }

        var isInstalled: Bool {
            switch source {
            case .catalogOnly:     return false
            case .installedKnown, .installedCustom: return true
            }
        }

        var downloadURL: URL? {
            switch source {
            case .catalogOnly(let info), .installedKnown(let info, _):
                return info.downloadURL
            case .installedCustom:
                return nil
            }
        }
    }

    /// Per-row action available in the Status column. Drives the
    /// icon shown and what happens when the user clicks it.
    private enum RowAction {
        case download
        case delete
        case none   // active model — no direct action allowed
    }

    // MARK: - Public surface

    /// Fires when the user picks a new active model. AppDelegate
    /// hands this through to `RemoteDictationService.setActiveModel`.
    var onActiveModelChanged: ((String) -> Void)?

    // MARK: - UI

    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let activeLabel = NSTextField(labelWithString: "")
    private let useButton = NSButton(title: "Use Selected", target: nil, action: nil)
    private let cancelDownloadButton = NSButton(title: "Cancel Download", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    /// Held so we can flip `setVisibilityPriority(...)` on individual
    /// rows after init — collapses the progress/status rows out of
    /// the layout entirely when there's nothing to show, instead of
    /// leaving an empty band between the table and the bottom row.
    private var rootStack: NSStackView?
    private var progressRow: NSStackView?
    /// Resized after every `reloadRows()` so the scroll view is
    /// exactly as tall as the table content — no empty rows below
    /// the last model, no unnecessary scrollbar when fewer rows
    /// exist than would fit in a default-height window.
    private var scrollViewHeightConstraint: NSLayoutConstraint?

    // MARK: - State

    private var rows: [Row] = []
    private let downloader = ModelDownloader()
    private var downloadingFilename: String?

    // MARK: - Init

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 460),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Whisper Voice Models"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 560, height: 360)
        super.init(window: window)
        window.delegate = self
        buildLayout()
        reloadRows()
    }

    required init?(coder: NSCoder) { nil }

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        activeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        activeLabel.textColor = .secondaryLabelColor

        tableView.style = .inset
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .medium
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        // Distribute extra width to the Model column so the narrow
        // Size / Status columns keep their full content at any
        // window size.
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(useSelected)

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Model"
        nameCol.minWidth = 220
        nameCol.width = 340
        tableView.addTableColumn(nameCol)

        let sizeCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeCol.title = "Size"
        sizeCol.minWidth = 64
        sizeCol.width = 80
        tableView.addTableColumn(sizeCol)

        // Status column hosts a single click-target icon (cloud or
        // trash). 64 pt is plenty for a 22 pt icon with comfortable
        // padding on both sides.
        let statusCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("status"))
        statusCol.title = "Status"
        statusCol.minWidth = 60
        statusCol.width = 64
        tableView.addTableColumn(statusCol)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .bezelBorder
        scrollView.autohidesScrollers = true

        useButton.target = self
        useButton.action = #selector(useSelected)
        useButton.bezelStyle = .rounded

        cancelDownloadButton.target = self
        cancelDownloadButton.action = #selector(cancelDownload)
        cancelDownloadButton.bezelStyle = .rounded
        cancelDownloadButton.isHidden = true

        refreshButton.target = self
        refreshButton.action = #selector(refresh)
        refreshButton.bezelStyle = .rounded

        doneButton.target = self
        doneButton.action = #selector(donePressed)
        doneButton.bezelStyle = .rounded
        // Return is bound to Done — the canonical "I'm finished
        // with this window" action. Use Selected and Refresh stay
        // mouse-driven; pressing Return without a row selected
        // would have done nothing useful on Use Selected anyway.
        doneButton.keyEquivalent = "\r"

        statusLabel.font = .systemFont(ofSize: 11, weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.isHidden = true

        // Bottom row layout per the user spec:
        //   [Refresh] [Use Selected]            [Done]
        // Refresh + Use Selected are the secondary / row-targeted
        // actions, grouped on the left. Done is the dismissive
        // primary, far right, with Return as its key equivalent.
        let bottomRow = NSStackView(views: [refreshButton, useButton, NSView(), doneButton])
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 8
        bottomRow.distribution = .fill

        let progressRow = NSStackView(views: [progressBar, cancelDownloadButton])
        progressRow.orientation = .horizontal
        progressRow.spacing = 8
        progressRow.distribution = .fill
        self.progressRow = progressRow

        let stack = NSStackView(views: [activeLabel, scrollView, statusLabel, progressRow, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        // v43 collapsed the spacing to 8 pt which the user reported
        // as too tight; v42's 10 pt felt too airy. 12 pt is the
        // middle ground — comfortable breathing room between the
        // model list and the bottom button row without leaving a
        // visible "dead band" of empty space.
        stack.spacing = 12
        stack.distribution = .fill
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        self.rootStack = stack

        // Collapse the optional rows out of the layout entirely
        // when their content is empty / hidden, instead of leaving
        // an unsightly gap of dead space between the table and the
        // bottom button row. The visibility priority is bumped back
        // up the moment we have something to show in either row.
        stack.setVisibilityPriority(.notVisible, for: progressRow)
        stack.setVisibilityPriority(.notVisible, for: statusLabel)

        // The scroll view's height is driven by `reloadRows()` so
        // the table only shows as many rows as there are models —
        // no empty rows below the last one. The constraint is set
        // here with a placeholder constant; the real value comes
        // from `updateScrollViewHeight()` which runs after each
        // reload. Priority is bumped above the stack's natural
        // fill so the layout actually shrinks to fit content.
        let scrollHeight = scrollView.heightAnchor.constraint(equalToConstant: 260)
        scrollHeight.priority = NSLayoutConstraint.Priority(751)
        scrollHeight.isActive = true
        self.scrollViewHeightConstraint = scrollHeight

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 18),
            scrollView.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -18),
            bottomRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 18),
            bottomRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -18),
            progressRow.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 18),
            progressRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -18),
        ])

        downloader.onProgress = { [weak self] written, total in
            self?.updateDownloadProgress(written: written, total: total)
        }
        downloader.onComplete = { [weak self] result in
            self?.finishDownload(result: result)
        }
    }

    /// Flip the optional rows in/out of layout based on what's
    /// currently happening. Called whenever the state of the
    /// downloader or the status text changes.
    private func refreshOptionalRowVisibility(downloading: Bool) {
        guard let stack = rootStack, let progressRow else { return }
        stack.setVisibilityPriority(
            downloading ? .mustHold : .notVisible,
            for: progressRow
        )
        stack.setVisibilityPriority(
            statusLabel.stringValue.isEmpty ? .notVisible : .mustHold,
            for: statusLabel
        )
    }

    private func setStatusMessage(_ message: String) {
        statusLabel.stringValue = message
        refreshOptionalRowVisibility(downloading: downloader.isRunning)
    }

    @objc private func donePressed() {
        if downloader.isRunning {
            downloader.cancel()
        }
        close()
    }

    // MARK: - Reload / refresh

    private func reloadRows() {
        let installed = WhisperModelStore.installedModels()
        let installedByFilename = Dictionary(uniqueKeysWithValues: installed.map { ($0.filename, $0) })
        let activeFilename = (WhisperModelStore.activeModelPath() as NSString).lastPathComponent

        var entries: [Row] = []

        for info in WhisperModelInfo.catalog {
            if let installedModel = installedByFilename[info.filename] {
                entries.append(Row(
                    source: .installedKnown(info, installedModel),
                    isActive: installedModel.filename == activeFilename
                ))
            } else if info.downloadURL != nil {
                // Skip catalog entries that have no download URL AND
                // aren't installed — they're effectively unavailable
                // and would show an empty Status cell. The user
                // explicitly asked for "no unavailable rows."
                entries.append(Row(
                    source: .catalogOnly(info),
                    isActive: false
                ))
            }
        }

        let catalogFilenames = Set(WhisperModelInfo.catalog.map(\.filename))
        for installedModel in installed where !catalogFilenames.contains(installedModel.filename) {
            entries.append(Row(
                source: .installedCustom(installedModel),
                isActive: installedModel.filename == activeFilename
            ))
        }

        rows = entries
        tableView.reloadData()
        updateActiveLabel(activeFilename: activeFilename, installed: installedByFilename)
        updateButtonStates()
        updateScrollViewHeight()
    }

    /// Computes the "ideal" content height — exactly enough to
    /// show every model row with no scroll bar — and:
    ///   - Caps the scroll view's height constraint to it so the
    ///     table doesn't try to grow beyond its content.
    ///   - Sets the window's `maxSize` to the same value, so the
    ///     user can't drag the window taller and produce a trailing
    ///     band of dead space below the bottom button row.
    ///   - Resizes the window's content size to match exactly,
    ///     which (combined with the maxSize cap) is the user's
    ///     "default state = full model list, no scrollbar" goal.
    ///
    /// Shrinking is left unrestricted — `window.minSize` stays at
    /// the existing 560 × 360, and any vertical shortfall just
    /// activates the table's vertical scroller.
    private func updateScrollViewHeight() {
        guard let window = self.window,
              let content = window.contentView,
              let constraint = scrollViewHeightConstraint else { return }

        let rowHeight = tableView.rowHeight + tableView.intercellSpacing.height
        let headerHeight = tableView.headerView?.bounds.height ?? 22
        let tablePadding: CGFloat = 8       // .inset style inner padding
        let neededTable = CGFloat(rows.count) * rowHeight + headerHeight + tablePadding

        constraint.constant = neededTable

        // Force-layout so `content.fittingSize` reflects the new
        // constraint constant before we read it.
        content.layoutSubtreeIfNeeded()
        let fittingContent = content.fittingSize
        guard fittingContent.height > 0 else { return }

        // Convert the content-rect fitting size into a *frame* size
        // (which is what `NSWindow.maxSize` takes — content + title
        // bar). Width stays uncapped on the high side (1200 is a
        // reasonable upper bound for super-wide displays).
        let contentRect = NSRect(origin: .zero, size: fittingContent)
        let frameRect = window.frameRect(forContentRect: contentRect)
        window.maxSize = NSSize(width: 1200, height: frameRect.height)

        // Snap the window to the new ideal height. We only resize
        // when the difference is meaningful so we don't churn the
        // window position during identity-noop reloads.
        let currentContentHeight = content.bounds.height
        if abs(currentContentHeight - fittingContent.height) > 2 {
            let currentFrame = window.frame
            let targetContent = NSSize(
                width: max(currentFrame.width - (frameRect.width - fittingContent.width),
                           fittingContent.width),
                height: fittingContent.height
            )
            window.setContentSize(targetContent)
        }
    }

    private func updateActiveLabel(activeFilename: String, installed: [String: InstalledWhisperModel]) {
        if let installedActive = installed[activeFilename] {
            let size = WhisperModelStore.formatBytes(installedActive.sizeBytes)
            activeLabel.stringValue = "Active model: \(activeFilename)  ·  \(size)"
        } else {
            activeLabel.stringValue = "Active model: \(activeFilename)  ·  not installed (will fail until downloaded)"
        }
    }

    @objc private func refresh() {
        reloadRows()
        if statusLabel.stringValue.isEmpty {
            setStatusMessage("Refreshed.")
        }
    }

    // MARK: - Actions

    @objc private func useSelected() {
        guard let row = selectedRow(), row.isInstalled, !row.isActive else { return }
        WhisperModelStore.setActiveModelFilename(row.filename)
        onActiveModelChanged?(row.filename)
        setStatusMessage("Switched active model to \(row.filename).")
        reloadRows()
    }

    /// Wired to the trash icon in the Status column.
    private func deleteRow(_ row: Row) {
        guard row.isInstalled else { return }
        if row.isActive {
            setStatusMessage("Cannot delete the active model. Switch to a different model first.")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete \(row.filename)?"
        alert.informativeText = "This removes the file from ~/.cache/whisper/. You can re-download it later from this window."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try WhisperModelStore.deleteModel(filename: row.filename)
            setStatusMessage("Deleted \(row.filename).")
        } catch {
            setStatusMessage("Delete failed: \(error.localizedDescription)")
        }
        reloadRows()
    }

    /// Wired to the cloud-download icon in the Status column.
    private func downloadRow(_ row: Row) {
        guard !row.isInstalled, let url = row.downloadURL else { return }
        if downloader.isRunning {
            setStatusMessage("A download is already in progress.")
            return
        }
        WhisperModelStore.ensureCacheDirectoryExists()
        let dest = (WhisperModelStore.cacheDirectoryPath as NSString).appendingPathComponent(row.filename)
        downloadingFilename = row.filename
        progressBar.doubleValue = 0
        progressBar.isHidden = false
        cancelDownloadButton.isHidden = false
        useButton.isEnabled = false
        refreshButton.isEnabled = false
        // Bump statusLabel + progressRow back into the layout BEFORE
        // setting the message, otherwise the row collapses again on
        // the next refresh tick if the message happens to be empty.
        refreshOptionalRowVisibility(downloading: true)
        setStatusMessage("Downloading \(row.filename)…")
        tableView.reloadData()
        downloader.start(from: url, savingTo: dest)
    }

    @objc private func cancelDownload() {
        downloader.cancel()
    }

    // MARK: - Download progress

    private func updateDownloadProgress(written: Int64, total: Int64) {
        guard let filename = downloadingFilename else { return }
        if total > 0 {
            let frac = Double(written) / Double(total)
            progressBar.doubleValue = max(0, min(1, frac))
            let writtenStr = WhisperModelStore.formatBytes(written)
            let totalStr = WhisperModelStore.formatBytes(total)
            setStatusMessage("Downloading \(filename): \(writtenStr) / \(totalStr) (\(Int(frac * 100))%)")
        } else {
            progressBar.isIndeterminate = true
            progressBar.startAnimation(nil)
            setStatusMessage("Downloading \(filename): \(WhisperModelStore.formatBytes(written))")
        }
    }

    private func finishDownload(result: Result<URL, Error>) {
        let filename = downloadingFilename
        downloadingFilename = nil
        progressBar.stopAnimation(nil)
        progressBar.isIndeterminate = false
        progressBar.isHidden = true
        cancelDownloadButton.isHidden = true
        refreshButton.isEnabled = true

        switch result {
        case .success(let url):
            setStatusMessage("Downloaded \(url.lastPathComponent).")
        case .failure(let error):
            if let de = error as? ModelDownloader.DownloadError, case .cancelled = de {
                setStatusMessage("Download cancelled.")
                if let filename {
                    let dest = (WhisperModelStore.cacheDirectoryPath as NSString)
                        .appendingPathComponent(filename)
                    try? FileManager.default.removeItem(atPath: dest)
                }
            } else {
                setStatusMessage("Download failed: \(error.localizedDescription)")
            }
        }
        // Collapse the progressRow back out of the layout — no
        // download means no progress bar means no need for the
        // band of dead space below the table.
        refreshOptionalRowVisibility(downloading: false)
        reloadRows()
    }

    // MARK: - Selection / buttons

    private func selectedRow() -> Row? {
        let idx = tableView.selectedRow
        guard idx >= 0, idx < rows.count else { return nil }
        return rows[idx]
    }

    private func updateButtonStates() {
        let row = selectedRow()
        useButton.isEnabled = (row?.isInstalled == true) && (row?.isActive == false) && !downloader.isRunning
    }

    /// What direct-action icon (if any) the Status column should
    /// show for this row.
    private func action(for row: Row) -> RowAction {
        if row.isActive { return .none }
        if row.isInstalled { return .delete }
        if row.downloadURL != nil { return .download }
        return .none
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if downloader.isRunning {
            downloader.cancel()
        }
    }

    // Closes the window when the user presses Escape. NSWindow's
    // responder chain forwards cancel operations to the window
    // controller when the window is key.
    override func cancelOperation(_ sender: Any?) {
        if downloader.isRunning {
            downloader.cancel()
        }
        close()
    }
}

// MARK: - NSTableViewDataSource / Delegate

extension ModelManagerWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row idx: Int) -> NSView? {
        guard idx >= 0, idx < rows.count, let column = tableColumn else { return nil }
        let row = rows[idx]

        switch column.identifier.rawValue {
        case "name":
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView)
                ?? makeNameCell()
            cell.textField?.stringValue = row.displayName
            // Only the active row shows a left-side checkmark. Other
            // rows leave the icon view empty (cell layout still
            // reserves the 22 pt slot so text alignment stays
            // consistent across rows).
            cell.imageView?.image = row.isActive ? activeIndicatorImage() : nil
            if let secondary = cell.viewWithTag(101) as? NSTextField {
                secondary.stringValue = row.filename + "  ·  " + row.summary
            }
            return cell
        case "size":
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? NSTableCellView)
                ?? makePlainTextCell(identifier: column.identifier)
            cell.textField?.stringValue = row.sizeLabel
            return cell
        case "status":
            let cell = (tableView.makeView(withIdentifier: column.identifier, owner: nil) as? StatusActionCell)
                ?? StatusActionCell(identifier: column.identifier)
            configure(statusCell: cell, for: row, at: idx)
            return cell
        default:
            return nil
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonStates()
    }

    private func configure(statusCell cell: StatusActionCell, for row: Row, at index: Int) {
        switch action(for: row) {
        case .download:
            cell.configure(
                image: cellSymbol("icloud.and.arrow.down", tint: .systemBlue),
                tooltip: "Download \(row.filename)",
                enabled: !downloader.isRunning,
                onClick: { [weak self] in self?.downloadRow(row) }
            )
        case .delete:
            // Trash icon uses `.systemRed` per Apple HIG: destructive
            // actions should signal their consequence with red.
            // Matches the "Delete" button colour in NSAlert and the
            // trash glyph in macOS Settings → Storage / iCloud.
            cell.configure(
                image: cellSymbol("trash", tint: .systemRed),
                tooltip: "Delete \(row.filename)",
                enabled: !downloader.isRunning,
                onClick: { [weak self] in self?.deleteRow(row) }
            )
        case .none:
            cell.clear()
        }
        // Visually mute the cell if the row's filename is currently
        // being downloaded — the cancel-download button at the
        // bottom handles cancellation in that mode.
        if downloadingFilename == row.filename {
            cell.clear()
        }
        _ = index  // reserved for future per-row state animation
    }

    private func makeNameCell() -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = NSUserInterfaceItemIdentifier("name")

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        cell.imageView = imageView
        cell.addSubview(imageView)

        let primary = NSTextField(labelWithString: "")
        primary.font = .systemFont(ofSize: 13, weight: .medium)
        primary.lineBreakMode = .byTruncatingTail
        primary.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = primary
        cell.addSubview(primary)

        let secondary = NSTextField(labelWithString: "")
        secondary.font = .systemFont(ofSize: 11, weight: .regular)
        secondary.textColor = .secondaryLabelColor
        secondary.tag = 101
        secondary.lineBreakMode = .byTruncatingTail
        secondary.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(secondary)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 22),
            imageView.heightAnchor.constraint(equalToConstant: 22),
            primary.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 8),
            primary.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            primary.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),
            secondary.leadingAnchor.constraint(equalTo: primary.leadingAnchor),
            secondary.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            secondary.topAnchor.constraint(equalTo: primary.bottomAnchor, constant: 2),
        ])
        return cell
    }

    private func makePlainTextCell(identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let primary = NSTextField(labelWithString: "")
        primary.font = .systemFont(ofSize: 13, weight: .medium)
        primary.lineBreakMode = .byTruncatingTail
        primary.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = primary
        cell.addSubview(primary)
        NSLayoutConstraint.activate([
            primary.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            primary.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            primary.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// The left-column "this is the active model" checkmark icon.
    /// Identical render to the Bluetooth-access success icon: white
    /// check baked over an accent-coloured filled circle.
    private func activeIndicatorImage() -> NSImage? {
        guard let image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Active") else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white, .controlAccentColor]))
        let tinted = image.withSymbolConfiguration(config) ?? image
        tinted.isTemplate = false
        return tinted
    }

    /// Generic single-colour SF Symbol used for the Status-column
    /// action icons (cloud / trash). One layer each, so a
    /// single-element palette is fine.
    private func cellSymbol(_ name: String, tint: NSColor) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [tint]))
        let tinted = image.withSymbolConfiguration(config) ?? image
        tinted.isTemplate = false
        return tinted
    }
}

// MARK: - Status column cell

/// Custom `NSTableCellView` that hosts a single click-target icon
/// (download or delete). Using a borderless `NSButton` rather than
/// an `NSImageView` ensures the cell participates in the normal
/// AppKit click handling — including hover feedback when the
/// pointer is over it — without needing a custom gesture
/// recognizer.
final class StatusActionCell: NSTableCellView {
    private let button = NSButton()
    private var onClick: (() -> Void)?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        button.target = self
        button.action = #selector(buttonClicked)
        button.isBordered = false
        button.bezelStyle = .regularSquare
        button.imagePosition = .imageOnly
        button.imageScaling = .scaleProportionallyDown
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)
        NSLayoutConstraint.activate([
            button.centerXAnchor.constraint(equalTo: centerXAnchor),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            button.widthAnchor.constraint(equalToConstant: 28),
            button.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func configure(image: NSImage?, tooltip: String, enabled: Bool, onClick: @escaping () -> Void) {
        button.image = image
        button.toolTip = tooltip
        button.isEnabled = enabled
        button.isHidden = image == nil
        self.onClick = onClick
    }

    func clear() {
        button.image = nil
        button.toolTip = nil
        button.isEnabled = false
        button.isHidden = true
        onClick = nil
    }

    @objc private func buttonClicked() {
        onClick?()
    }
}
