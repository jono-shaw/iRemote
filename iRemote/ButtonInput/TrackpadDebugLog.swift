import Foundation

/// Optional CSV log of every Siri Remote touchpad sample the trackpad
/// driver processes. Enabled by setting the environment variable
/// `IREMOTE_TRACKPAD_DEBUG=1` before launching iRemote. When disabled
/// the driver doesn't construct one of these, so there is no overhead.
///
/// File: `~/Library/Logs/iRemote-trackpad-debug.csv`. A header row is
/// written when the file is created. Existing files are reopened in
/// append mode so multiple sessions accumulate.
///
/// **Why this exists.** Every Y-axis "fix" between v22 and v33 was a
/// guess about what the raw values look like. With this log a single
/// labelled swipe ("user just swiped DOWN") produces ground-truth data
/// we can analyze to derive the right calibration matrix or diagnose
/// remaining issues without further user trial-and-error.
final class TrackpadDebugLog: @unchecked Sendable {
    private let handle: FileHandle?
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return df
    }()

    init() {
        let logsDir = (NSString(string: "~/Library/Logs").expandingTildeInPath as NSString)
        let path = logsDir.appendingPathComponent("iRemote-trackpad-debug.csv")
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
            let header = "timestamp,rawX,rawY,rawDx,rawDy,visualDx,visualDy,outDx,outDy,focusX,focusY\n"
            try? header.data(using: .utf8).map { try Data($0).write(to: url) }
        }
        self.handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
    }

    deinit {
        try? handle?.close()
    }

    func append(
        rawX: Int, rawY: Int,
        rawDx: Int, rawDy: Int,
        visualDx: Double, visualDy: Double,
        outDx: Double, outDy: Double,
        focusX: CGFloat, focusY: CGFloat
    ) {
        guard let handle else { return }
        let line = String(
            format: "%@,%d,%d,%d,%d,%.3f,%.3f,%.3f,%.3f,%.1f,%.1f\n",
            dateFormatter.string(from: Date()),
            rawX, rawY, rawDx, rawDy,
            visualDx, visualDy, outDx, outDy,
            focusX, focusY
        )
        if let data = line.data(using: .utf8) {
            try? handle.write(contentsOf: data)
        }
    }
}
