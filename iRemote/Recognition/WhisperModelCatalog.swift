import Foundation

/// One known Whisper model in the catalog (a model the user can choose
/// to download from Hugging Face's `ggerganov/whisper.cpp` repo).
struct WhisperModelInfo: Equatable, Hashable, Sendable {
    let filename: String
    let displayName: String
    let summary: String
    /// Approximate on-disk size in megabytes. Used for the catalog
    /// list and download-progress total estimate when the server
    /// doesn't provide a Content-Length.
    let approxSizeMB: Int
    let isMultilingual: Bool
    let downloadURL: URL?
}

extension WhisperModelInfo {
    /// Hugging Face mirror of ggml-format Whisper models. URLs are
    /// stable across releases. Sizes are approximate (the actual file
    /// is reported via Content-Length at download time).
    static let catalog: [WhisperModelInfo] = [
        .init(
            filename: "ggml-tiny.bin",
            displayName: "Tiny",
            summary: "Multilingual · fastest · low accuracy",
            approxSizeMB: 75,
            isMultilingual: true,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin")
        ),
        .init(
            filename: "ggml-tiny.en.bin",
            displayName: "Tiny (English only)",
            summary: "English-only · fastest · low accuracy",
            approxSizeMB: 75,
            isMultilingual: false,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.en.bin")
        ),
        .init(
            filename: "ggml-base.bin",
            displayName: "Base",
            summary: "Multilingual · fast · basic accuracy",
            approxSizeMB: 142,
            isMultilingual: true,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin")
        ),
        .init(
            filename: "ggml-base.en.bin",
            displayName: "Base (English only)",
            summary: "English-only · fast · basic accuracy",
            approxSizeMB: 142,
            isMultilingual: false,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")
        ),
        .init(
            filename: "ggml-small.bin",
            displayName: "Small (default)",
            summary: "Multilingual · balanced speed/accuracy · current default",
            approxSizeMB: 466,
            isMultilingual: true,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin")
        ),
        .init(
            filename: "ggml-small.en.bin",
            displayName: "Small (English only)",
            summary: "English-only · balanced speed/accuracy",
            approxSizeMB: 466,
            isMultilingual: false,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.en.bin")
        ),
        .init(
            filename: "ggml-medium.bin",
            displayName: "Medium",
            summary: "Multilingual · slower · higher accuracy",
            approxSizeMB: 1500,
            isMultilingual: true,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin")
        ),
        .init(
            filename: "ggml-large-v3-turbo.bin",
            displayName: "Large v3 Turbo (recommended upgrade)",
            summary: "Multilingual · near-large accuracy at ~5× the speed of large-v3",
            approxSizeMB: 1500,
            isMultilingual: true,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin")
        ),
        .init(
            filename: "ggml-large-v3-turbo-q5_0.bin",
            displayName: "Large v3 Turbo (5-bit quantized)",
            summary: "Multilingual · ~half the size of large-v3-turbo · slight accuracy loss",
            approxSizeMB: 550,
            isMultilingual: true,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")
        ),
        .init(
            filename: "ggml-large-v3.bin",
            displayName: "Large v3",
            summary: "Multilingual · best accuracy · slowest",
            approxSizeMB: 2900,
            isMultilingual: true,
            downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin")
        ),
    ]

    static func catalogEntry(forFilename filename: String) -> WhisperModelInfo? {
        catalog.first { $0.filename == filename }
    }
}

/// One Whisper model file currently sitting in `~/.cache/whisper/`.
struct InstalledWhisperModel: Equatable, Sendable {
    let filename: String
    let path: String
    let sizeBytes: Int64
}

/// File-system + UserDefaults bridge for installed models and the
/// currently-active selection.
enum WhisperModelStore {
    static let cacheDirectoryPath: String =
        (NSString("~/.cache/whisper").expandingTildeInPath as NSString) as String

    /// UserDefaults key holding the filename (not full path) of the
    /// currently-active model. RemoteDictationService reads this at
    /// init and the model manager rewrites it on switch.
    static let activeModelDefaultsKey = "iRemote.whisperActiveModel"

    /// Resolves the active model's full path. Falls back to
    /// `ggml-small.bin` if no UserDefaults entry exists. The env var
    /// `IREMOTE_WHISPER_MODEL` is honoured as an override for
    /// developer workflows.
    static func activeModelPath() -> String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["IREMOTE_WHISPER_MODEL"], !override.isEmpty {
            return override
        }
        let filename = UserDefaults.standard.string(forKey: activeModelDefaultsKey)
            ?? "ggml-small.bin"
        return (cacheDirectoryPath as NSString).appendingPathComponent(filename)
    }

    static func setActiveModelFilename(_ filename: String) {
        UserDefaults.standard.set(filename, forKey: activeModelDefaultsKey)
    }

    /// Lists every `*.bin` file in the cache directory. Returns an
    /// empty array if the directory doesn't exist yet.
    static func installedModels() -> [InstalledWhisperModel] {
        let fm = FileManager.default
        let dir = cacheDirectoryPath
        guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { return [] }
        return entries
            .filter { $0.hasSuffix(".bin") }
            .compactMap { filename -> InstalledWhisperModel? in
                let path = (dir as NSString).appendingPathComponent(filename)
                let attrs = try? fm.attributesOfItem(atPath: path)
                let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
                return InstalledWhisperModel(filename: filename, path: path, sizeBytes: size)
            }
            .sorted { $0.filename < $1.filename }
    }

    static func deleteModel(filename: String) throws {
        let path = (cacheDirectoryPath as NSString).appendingPathComponent(filename)
        try FileManager.default.removeItem(atPath: path)
    }

    static func ensureCacheDirectoryExists() {
        try? FileManager.default.createDirectory(
            atPath: cacheDirectoryPath,
            withIntermediateDirectories: true
        )
    }

    /// Formats a byte count as a short human-readable string.
    /// `1_572_864_000` → `"1.5 GB"`.
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useMB, .useGB]
        return formatter.string(fromByteCount: bytes)
    }
}
