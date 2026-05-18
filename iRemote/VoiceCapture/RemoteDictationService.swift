import Foundation

struct RemoteDictationResult {
    let transcript: String
    let wavPath: String?
    let processedWavPath: String?
    let workDir: String?
    let rawOutput: String
    let opusFrameCount: Int
}

enum RemoteListenerEvent {
    case listening(String)
    case captureActive(Int)
    case recording
    case transcribing
    case result(RemoteDictationResult)
    case failed(String)
    case stopped
    case remoteButton(code: UInt8)
    case touchpadSample(RemoteTouchpadSample)
}

enum RemoteDictationServiceError: LocalizedError {
    case missingTool(String)
    case failed(String)
    case emptyTranscript(String)

    var errorDescription: String? {
        switch self {
        case .missingTool(let message), .failed(let message), .emptyTranscript(let message):
            return message
        }
    }
}


private final class RemoteTextVoiceParser {
    private struct InflightPDU {
        var attHandle: UInt16
        var pduTotalLen: Int
        var valueExpected: Int
        var valueTruncated: Int
        var collected: [UInt8]
    }

    private static let voiceAttHandle: UInt16 = 0x0023
    private static let hidReportLength = 101
    private static let voicePacketLengthOffset = 6
    private static let voicePacketPayloadOffset = 7

    private var inflight: [UInt16: InflightPDU] = [:]

    func parse(line: String) -> [Data] {
        guard let bytes = parseHexPayload(from: line) else { return [] }
        return processACL(bytes)
    }

    private func parseHexPayload(from line: String) -> [UInt8]? {
        let payloadText: Substring
        if let tab = line.firstIndex(of: "\t") {
            payloadText = line[line.index(after: tab)...].split(separator: "\t").first ?? ""
        } else {
            payloadText = Substring(line)
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(128)
        for tokenSub in payloadText.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let token = String(tokenSub)
            guard token.count == 2, let byte = UInt8(token, radix: 16) else { continue }
            bytes.append(byte)
        }
        return bytes.isEmpty ? nil : bytes
    }

    private func processACL(_ bytes: [UInt8]) -> [Data] {
        guard bytes.count >= 4 else { return [] }
        let handleField = Self.le16(bytes, 0)
        let connHandle = handleField & 0x0fff
        let pbFlag = (handleField >> 12) & 0x3
        let aclLenWire = Int(Self.le16(bytes, 2))
        guard connHandle != 0, aclLenWire > 0 else { return [] }

        let available = max(0, bytes.count - 4)
        let aclDataCount = min(aclLenWire, available)
        guard aclDataCount > 0 else { return [] }
        let aclData = Array(bytes[4..<(4 + aclDataCount)])

        if pbFlag == 0b10 {
            guard aclData.count >= 7 else { return [] }
            let l2capLen = Int(Self.le16(aclData, 0))
            let l2capCID = Self.le16(aclData, 2)
            guard l2capCID == 0x0004 else { return [] }

            let opcode = aclData[4]
            let attHandle = Self.le16(aclData, 5)
            guard opcode == 0x1b || opcode == 0x1d else { return [] }

            let valueExpected = max(0, l2capLen - 3)
            let wireValueInStart = max(0, aclLenWire - 4 - 3)
            let actualValueInStart = max(0, aclData.count - 7)
            let truncated = max(0, wireValueInStart - actualValueInStart)
            let value = actualValueInStart > 0 ? Array(aclData[7..<aclData.count]) : []

            inflight[connHandle] = InflightPDU(
                attHandle: attHandle,
                pduTotalLen: l2capLen,
                valueExpected: valueExpected,
                valueTruncated: truncated,
                collected: value
            )
            return completeIfReady(connHandle: connHandle)
        }

        if pbFlag == 0b01 {
            guard var pdu = inflight[connHandle] else { return [] }
            pdu.collected.append(contentsOf: aclData)
            inflight[connHandle] = pdu
            return completeIfReady(connHandle: connHandle)
        }

        return []
    }

    private func completeIfReady(connHandle: UInt16) -> [Data] {
        guard let pdu = inflight[connHandle] else { return [] }
        guard pdu.collected.count + pdu.valueTruncated >= pdu.valueExpected else { return [] }
        inflight.removeValue(forKey: connHandle)

        guard pdu.attHandle == Self.voiceAttHandle else { return [] }
        guard pdu.valueTruncated == 0 else { return [] }
        guard pdu.pduTotalLen >= 100, pdu.collected.count >= Self.hidReportLength else { return [] }
        guard pdu.collected.count > Self.voicePacketPayloadOffset else { return [] }

        let packetLength = Int(pdu.collected[Self.voicePacketLengthOffset])
        let packetEnd = Self.voicePacketPayloadOffset + packetLength
        guard packetLength > 0, packetEnd <= pdu.collected.count else { return [] }
        return [Data(pdu.collected[Self.voicePacketPayloadOffset..<packetEnd])]
    }

    private static func le16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }
}

@MainActor
final class RemoteDictationService {
    let projectRoot: String
    let packetLoggerPath: String
    let scriptPath: String
    let whisperCLIPath: String
    /// Mutable so the user can switch active models at runtime via
    /// `ModelManagerWindowController` without restarting the app. The
    /// next `transcribe(...)` call picks up the new path
    /// automatically — whisper-cli loads the model fresh on each
    /// invocation, so there is no in-memory state to invalidate.
    private(set) var whisperModelPath: String
    private(set) var language: String

    /// Initial-prompt text fed to whisper-cli. Three-part design that
    /// substantially improves transcription quality for Mandarin and
    /// mixed Mandarin/English audio:
    ///
    /// 1. Comma-heavy Mandarin run-on sentence — biases the decoder
    ///    toward inserting full-width commas at clause boundaries
    ///    and a full-width period at the end.
    /// 2. Explicit Mandarin punctuation vocabulary — primes the
    ///    decoder to recognise the spoken names of punctuation marks
    ///    (`comma`, `period`, `question mark`, etc.) instead of
    ///    falling into homophone gibberish that some Whisper sizes
    ///    are prone to.
    /// 3. English tail — keeps mixed-language audio well-punctuated;
    ///    the English half doesn't need help because Whisper handles
    ///    English punctuation natively.
    ///
    /// The Mandarin sentences below are *functional* — removing them
    /// would noticeably degrade Chinese transcription quality. They
    /// are intentionally retained.
    fileprivate static let punctuationPrompt =
        "你好，我叫小王，今天天气很好，我打算去公园散步，顺便买点水果，回家做饭。" +
        "逗号、句号、问号、感叹号、顿号、冒号都是标点符号。" +
        "Hello, my name is Sam, and the weather is great."

    private let launchDaemonLabel = "com.iremote.packetlogger"
    private let launchDaemonPlistPath = "/Library/LaunchDaemons/com.iremote.packetlogger.plist"
    private let captureHelperPath = "/usr/local/bin/iremote-capture-helper"
    private let sudoersPath = "/etc/sudoers.d/iremote-packetlogger"
    private let extractorPath = "/tmp/extract-remote-opus"
    private let decoderPath = "/tmp/decode-remote-opus-v3"
    private let rollingWorkDir = "/tmp/iremote-window-live"
    private var currentFrames: [Data] = []
    private var micButtonHeld = false
    private var voiceMonitor: RemotePklgVoiceMonitor?
    private var streamFinalizeTask: Task<Void, Never>?
    private var activeRollingWorkDir: String?
    private var eventHandler: ((RemoteListenerEvent) -> Void)?
    private var isListening = false
    private var isFinalizing = false
    private var finalizeArmed = false
    private let autoFinalizeNanos: UInt64 = 900_000_000
    private let releaseFinalizeNanos: UInt64 = 350_000_000

    init(projectRoot: String? = nil) {
        let env = ProcessInfo.processInfo.environment
        // The "project root" is the directory that holds the
        // helper scripts iRemote compiles + executes at runtime
        // (Tools/extract-remote-opus.swift,
        // Tools/decode-remote-opus.c, Tools/remote-dictate-once.sh).
        // When running from the shipped .app these live inside the
        // bundle at Contents/Resources/. The environment-variable
        // override is kept for developer convenience when running
        // an unbundled build.
        self.projectRoot = projectRoot
            ?? env["IREMOTE_PROJECT_ROOT"]
            ?? Self.bundledProjectRoot()
        self.packetLoggerPath = env["IREMOTE_PACKETLOGGER"]
            ?? Self.locatePacketLogger()
        self.scriptPath = env["IREMOTE_REMOTE_DICTATE_SCRIPT"]
            ?? "\(self.projectRoot)/Tools/remote-dictate-once.sh"
        self.whisperCLIPath = env["IREMOTE_WHISPER_CLI"]
            ?? Self.locateWhisperCLI()
        // Active-model resolution order: IREMOTE_WHISPER_MODEL env
        // override → UserDefaults selection (set by the model
        // manager) → built-in default ggml-small.bin.
        self.whisperModelPath = WhisperModelStore.activeModelPath()
        self.language = env["IREMOTE_WHISPER_LANG"]
            ?? (Self.isEnglishOnlyModel(self.whisperModelPath) ? "en" : "auto")
    }

    /// Where the bundled Tools/ scripts live for the running app.
    /// In a built .app this is `Contents/Resources/`; the helper
    /// sources are bundled in there at `Resources/Tools/`. The
    /// existing string formatting (`"\(projectRoot)/Tools/..."`)
    /// just appends from there, so we hand back the resource path
    /// minus a trailing slash. Falls back to the current directory
    /// for the rare case of running unbundled with no env var set.
    private static func bundledProjectRoot() -> String {
        if let resourceURL = Bundle.main.resourceURL,
           FileManager.default.fileExists(atPath: resourceURL.appendingPathComponent("Tools").path) {
            return resourceURL.path
        }
        return FileManager.default.currentDirectoryPath
    }

    /// PacketLogger ships with Apple's "Additional Tools for Xcode"
    /// bundle. There is no canonical install location — developers
    /// drop the app wherever they downloaded it, most commonly
    /// `/Applications/` or `~/Downloads/`. Search a small list of
    /// likely paths and return the first executable we find.
    private static func locatePacketLogger() -> String {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let inner = "/PacketLogger.app/Contents/Resources/packetlogger"
        let candidates = [
            "/Applications" + inner,
            "\(home)/Applications" + inner,
            "\(home)/Downloads" + inner,
            "\(home)/Desktop" + inner,
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        // Return the first candidate as a placeholder so the
        // "missing" readiness check below has a concrete path to
        // mention in its log line.
        return candidates[0]
    }

    /// whisper-cli is the `whisper.cpp` command-line tool, typically
    /// installed via Homebrew. Check both the Apple Silicon and the
    /// Intel Homebrew prefixes plus `/usr/local/bin` for non-Homebrew
    /// installs.
    private static func locateWhisperCLI() -> String {
        let fm = FileManager.default
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",  // Homebrew on Apple Silicon
            "/usr/local/bin/whisper-cli",     // Homebrew on Intel + manual installs
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return path
        }
        return candidates[0]
    }

    /// Switches the active model at runtime. Called by AppDelegate
    /// when the model manager hands back a new filename. Updates the
    /// path used by subsequent `whisper-cli` invocations and re-derives
    /// the language hint from the filename (English-only models pin
    /// language to `en`; everything else stays on `auto`).
    func setActiveModel(filename: String) {
        let path = (WhisperModelStore.cacheDirectoryPath as NSString)
            .appendingPathComponent(filename)
        whisperModelPath = path
        let env = ProcessInfo.processInfo.environment
        language = env["IREMOTE_WHISPER_LANG"]
            ?? (Self.isEnglishOnlyModel(path) ? "en" : "auto")
        WhisperModelStore.setActiveModelFilename(filename)
    }

    var readinessLines: [String] {
        var lines: [String] = []
        let fm = FileManager.default

        lines.append(fm.isExecutableFile(atPath: packetLoggerPath)
                     ? "Remote capture: PacketLogger ready"
                     : "Remote capture: PacketLogger missing")
        lines.append(fm.isExecutableFile(atPath: whisperCLIPath)
                     ? "Whisper CLI: ready"
                     : "Whisper CLI: missing")

        if fm.fileExists(atPath: whisperModelPath) {
            let modelName = URL(fileURLWithPath: whisperModelPath).lastPathComponent
            lines.append("Model: \(modelName)")
            if modelName != "ggml-small.bin" {
                lines.append("Accuracy: install ggml-small.bin; current model is lower quality")
            }
        } else {
            lines.append("Model: missing \(URL(fileURLWithPath: whisperModelPath).lastPathComponent)")
        }

        lines.append(FileManager.default.isExecutableFile(atPath: captureHelperPath)
                     ? "Remote trigger helper: installed"
                     : "Remote trigger helper: will ask once to install")
        return lines
    }

    var readinessProblem: String? {
        let fm = FileManager.default
        if !fm.isExecutableFile(atPath: packetLoggerPath) {
            return "PacketLogger CLI not found"
        }
        if !fm.isExecutableFile(atPath: whisperCLIPath) {
            return "Whisper CLI not found"
        }
        if !fm.fileExists(atPath: whisperModelPath) {
            return "Whisper model not found: \(URL(fileURLWithPath: whisperModelPath).lastPathComponent)"
        }
        return nil
    }

    var preferredModelInstallHint: String {
        "curl -L --fail https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin -o ~/.cache/whisper/ggml-small.bin"
    }

    func ensureTriggeredCaptureReady() async throws {
        if await Self.captureHelperReady(captureHelperPath) {
            let helperPath = captureHelperPath
            _ = try? await Task.detached {
                try Self.runExecutable("/usr/bin/sudo", arguments: ["-n", helperPath, "cleanup-legacy"])
            }.value
            return
        }

        let user = NSUserName()
        let helperScript = Self.captureHelperScript(packetLoggerPath: packetLoggerPath)
        let sudoers = "\(user) ALL=(root) NOPASSWD: \(captureHelperPath)\n"
        let command = [
            "set -e",
            "/bin/launchctl bootout system/\(launchDaemonLabel) >/dev/null 2>&1 || true",
            "rm -f \(Self.shQuote(launchDaemonPlistPath))",
            "mkdir -p /usr/local/bin /etc/sudoers.d",
            "cat > \(Self.shQuote(captureHelperPath)) <<'IREMOTE_HELPER'",
            helperScript,
            "IREMOTE_HELPER",
            "chown root:wheel \(Self.shQuote(captureHelperPath))",
            "chmod 755 \(Self.shQuote(captureHelperPath))",
            "cat > \(Self.shQuote(sudoersPath)) <<'IREMOTE_SUDOERS'",
            sudoers,
            "IREMOTE_SUDOERS",
            "chown root:wheel \(Self.shQuote(sudoersPath))",
            "chmod 440 \(Self.shQuote(sudoersPath))",
            "/usr/sbin/visudo -cf \(Self.shQuote(sudoersPath))",
        ].joined(separator: "\n")

        _ = try await Self.runWithAdministratorPrivileges(command)
        guard await Self.captureHelperReady(captureHelperPath) else {
            throw RemoteDictationServiceError.failed("Capture helper installed but sudo -n check failed")
        }
    }

    func startTriggeredCapture() async throws -> String {
        try await ensureTriggeredCaptureReady()
        let helperPath = captureHelperPath
        let workDir = "/tmp/iremote-trigger-\(UUID().uuidString)"

        return try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
            _ = try Self.runExecutable("/usr/bin/sudo", arguments: ["-n", helperPath, "start", workDir])
            return workDir
        }.value
    }

    func stopTriggeredCapture(workDir: String) async throws -> RemoteDictationResult {
        let helperPath = captureHelperPath
        let projectRoot = self.projectRoot
        let extractorPath = self.extractorPath
        let decoderPath = self.decoderPath
        let whisperCLIPath = self.whisperCLIPath
        let whisperModelPath = self.whisperModelPath
        let language = self.language

        return try await Task.detached(priority: .userInitiated) {
            _ = try Self.runExecutable("/usr/bin/sudo", arguments: ["-n", helperPath, "stop", workDir])
            return try Self.transcribeCapturedPklg(
                workDir: workDir,
                projectRoot: projectRoot,
                extractorPath: extractorPath,
                decoderPath: decoderPath,
                whisperCLIPath: whisperCLIPath,
                whisperModelPath: whisperModelPath,
                language: language
            )
        }.value
    }

    func startContinuousListening(onEvent: @escaping (RemoteListenerEvent) -> Void) {
        guard !isListening else { return }
        eventHandler = onEvent
        isListening = true
        Self.cleanupRollingCaptureDirs(keeping: rollingWorkDir)
        Self.pruneUtteranceDirs(maxCount: 8)

        voiceMonitor?.stop()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.ensureTriggeredCaptureReady()
                guard self.isListening, !Task.isCancelled else { return }
                try await self.startLivePklgCapture()
                onEvent(.listening("Listening for Remote mic continuous capture (-b)"))
            } catch {
                self.isListening = false
                onEvent(.failed(error.localizedDescription))
            }
        }
    }

    func stopContinuousListening() {
        isListening = false
        voiceMonitor?.stop()
        voiceMonitor = nil
        streamFinalizeTask?.cancel()
        streamFinalizeTask = nil
        micButtonHeld = false

        let helperPath = captureHelperPath
        let activeWorkDir = activeRollingWorkDir
        activeRollingWorkDir = nil
        if let activeWorkDir {
            Task.detached {
                _ = try? Self.runExecutable("/usr/bin/sudo", arguments: ["-n", helperPath, "stop", activeWorkDir])
                try? FileManager.default.removeItem(atPath: activeWorkDir)
            }
        } else {
            try? FileManager.default.removeItem(atPath: rollingWorkDir)
        }
        currentFrames.removeAll()
        eventHandler?(.stopped)
    }

    private func startLivePklgCapture() async throws {
        voiceMonitor?.stop()

        let helperPath = captureHelperPath
        let workDir = rollingWorkDir
        let pklgPath = "\(workDir)/remote.pklg"
        _ = try? await Task.detached(priority: .userInitiated) {
            try Self.runExecutable("/usr/bin/sudo", arguments: ["-n", helperPath, "stop", workDir])
        }.value
        try? FileManager.default.removeItem(atPath: workDir)
        activeRollingWorkDir = workDir

        _ = try await Task.detached(priority: .userInitiated) {
            try Self.runExecutable("/usr/bin/sudo", arguments: ["-n", helperPath, "start", workDir])
        }.value

        let monitor = RemotePklgVoiceMonitor(filePath: pklgPath, startAtEnd: false)
        voiceMonitor = monitor
        monitor.start(
            onBytes: { [weak self] byteCount in
                Self.dispatchOnMainAllModes { [weak self] in
                    MainActor.assumeIsolated {
                        self?.eventHandler?(.captureActive(byteCount))
                    }
                }
            },
            onFrame: { [weak self] frame in
                Self.dispatchOnMainAllModes { [weak self] in
                    MainActor.assumeIsolated {
                        self?.handleRemoteVoiceFrame(frame)
                    }
                }
            },
            onButton: { [weak self] code in
                Self.dispatchOnMainAllModes { [weak self] in
                    MainActor.assumeIsolated {
                        self?.eventHandler?(.remoteButton(code: code))
                    }
                }
            },
            onTouchpad: { [weak self] sample in
                Self.dispatchOnMainAllModes { [weak self] in
                    MainActor.assumeIsolated {
                        self?.eventHandler?(.touchpadSample(sample))
                    }
                }
            }
        )
    }

    /// Dispatches a block to the main thread in *every* mode the runloop
    /// may currently be in — including NSEventTrackingRunLoopMode (used
    /// while NSMenu modal-tracks a status-bar menu). Standard
    /// `Task { @MainActor in ... }` only runs in NSDefaultRunLoopMode, so
    /// events posted while the iRemote menu is open would queue up and
    /// fire only after the user manually closed it. This bypass keeps
    /// MENU-driven open/close responsive while the menu is on screen.
    private nonisolated static func dispatchOnMainAllModes(_ block: @escaping @Sendable () -> Void) {
        let modes: [RunLoop.Mode] = [.default, .common, .eventTracking, .modalPanel]
        RunLoop.main.perform(inModes: modes, block: block)
    }

    @discardableResult
    func setRemoteMicButtonDown(_ isDown: Bool) -> Bool {
        micButtonHeld = isDown
        if isDown {
            finalizeArmed = false
            streamFinalizeTask?.cancel()
            if isListening, currentFrames.isEmpty, !isFinalizing {
                eventHandler?(.recording)
            }
        } else {
            // Lock in a short finalize timer. Late-arriving voice frames
            // from PacketLogger's libc buffer must NOT push this deadline
            // back — otherwise the user perceives a 2-3s lag before the
            // .transcribing state appears.
            finalizeArmed = true
            scheduleFinalize(after: releaseFinalizeNanos)
        }
        return !currentFrames.isEmpty
    }

    private func handleRemoteVoiceFrame(_ frame: Data) {
        guard !frame.isEmpty else { return }

        let wasEmpty = currentFrames.isEmpty
        currentFrames.append(frame)
        if wasEmpty, !finalizeArmed {
            // Only emit .recording for a fresh utterance — not for late
            // PacketLogger flushes arriving after mic release.
            eventHandler?(.recording)
        }
        // Auto-finalize only applies when no button-driven finalize is
        // already armed. The release path owns the deadline; late frames
        // are captured if they squeak in before it fires but never extend
        // it.
        if !micButtonHeld, !finalizeArmed {
            scheduleFinalize(after: autoFinalizeNanos)
        }
    }

    private func scheduleFinalize(after delay: UInt64) {
        streamFinalizeTask?.cancel()
        streamFinalizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.finalizeCurrentUtterance()
        }
    }

    func dictate(duration: Int) async throws -> RemoteDictationResult {
        if let problem = readinessProblem {
            throw RemoteDictationServiceError.missingTool(problem)
        }

        let runID = UUID().uuidString
        let workDir = "/tmp/iremote-app-\(runID)"
        let environment = [
            "PATH=/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "PACKETLOGGER=\(Self.shQuote(packetLoggerPath))",
            "PACKETLOGGER_EXTRA_ARGS=-b",
            "DURATION=\(duration)",
            "RUN_ID=\(Self.shQuote(runID))",
            "WORK_DIR=\(Self.shQuote(workDir))",
            "INJECT=0",
            "WHISPER_CLI=\(Self.shQuote(whisperCLIPath))",
            "WHISPER_MODEL=\(Self.shQuote(whisperModelPath))",
            "WHISPER_LANG=\(Self.shQuote(language))",
            "WHISPER_EXTRA_ARGS=-ng",
        ].joined(separator: " ")
        let command = "cd \(Self.shQuote(projectRoot)) && \(environment) \(Self.shQuote(scriptPath))"

        let output = try await Self.runWithAdministratorPrivileges(command)
        let transcript = Self.parseValue(prefix: "Transcript:", in: output)
        let wavPath = Self.parseValue(prefix: "WAV:", in: output)

        guard let transcript, !transcript.isEmpty else {
            throw RemoteDictationServiceError.emptyTranscript(output)
        }

        return RemoteDictationResult(
            transcript: transcript,
            wavPath: wavPath,
            processedWavPath: nil,
            workDir: workDir,
            rawOutput: output,
            opusFrameCount: 0
        )
    }

    private func finalizeCurrentUtterance() async {
        guard !isFinalizing else { return }
        guard !currentFrames.isEmpty else {
            finalizeArmed = false
            return
        }

        isFinalizing = true
        finalizeArmed = false
        let frames = currentFrames
        currentFrames.removeAll()
        eventHandler?(.transcribing)

        do {
            let result = try await transcribe(opusFrames: frames)
            eventHandler?(.result(result))
        } catch {
            eventHandler?(.failed(error.localizedDescription))
        }
        isFinalizing = false
    }

    private func transcribe(opusFrames: [Data]) async throws -> RemoteDictationResult {
        let projectRoot = self.projectRoot
        let decoderPath = self.decoderPath
        let whisperCLIPath = self.whisperCLIPath
        let whisperModelPath = self.whisperModelPath
        let language = self.language

        return try await Task.detached(priority: .userInitiated) {
            let runID = UUID().uuidString
            let workDir = "/tmp/iremote-utt-\(runID)"
            try FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)

            let opusPath = "\(workDir)/remote-opus.bin"
            let wavPath = "\(workDir)/remote-raw.wav"
            let processedWavPath = "\(workDir)/remote-voice.wav"
            let whisperWavPath = "\(workDir)/remote-whisper.wav"
            let transcriptPath = "\(workDir)/transcript.txt"

            try Self.writeLengthPrefixedOpus(opusFrames, to: opusPath)
            try Self.ensureDecoderCompiled(projectRoot: projectRoot, decoderPath: decoderPath)
            _ = try Self.runExecutable(decoderPath, arguments: [opusPath, wavPath])

            let inputForWhisper = try Self.prepareAudioForWhisper(
                rawWavPath: wavPath,
                cleanedWavPath: processedWavPath,
                fallbackWavPath: whisperWavPath
            )

            let rawTranscript = try Self.runExecutable(
                whisperCLIPath,
                arguments: [
                    "-m", whisperModelPath,
                    "-f", inputForWhisper,
                    "-l", language,
                    "-t", "4",
                    // GPU on (Metal): ~5x faster than CPU-only on Apple
                    // Silicon for the small model. Do NOT pass -ng here.
                    "-nt",
                    "--no-prints",
                    "--prompt", Self.punctuationPrompt,
                ]
            )
            let cleaned = Self.cleanTranscript(rawTranscript)
            try cleaned.write(toFile: transcriptPath, atomically: true, encoding: .utf8)
            try? Self.publishLatestArtifacts(
                projectRoot: projectRoot,
                rawWavPath: wavPath,
                processedWavPath: inputForWhisper == wavPath ? nil : inputForWhisper,
                transcriptPath: transcriptPath,
                whisperModelPath: whisperModelPath,
                language: language,
                opusFrameCount: opusFrames.count
            )
            Self.pruneUtteranceDirs(maxCount: 8)

            guard !cleaned.isEmpty else {
                throw RemoteDictationServiceError.emptyTranscript("No transcript produced")
            }

            return RemoteDictationResult(
                transcript: cleaned,
                wavPath: wavPath,
                processedWavPath: inputForWhisper == wavPath ? nil : inputForWhisper,
                workDir: workDir,
                rawOutput: rawTranscript,
                opusFrameCount: opusFrames.count
            )
        }.value
    }

    private nonisolated static func captureHelperReady(_ helperPath: String) async -> Bool {
        await Task.detached {
            do {
                let version = try Self.runExecutable("/usr/bin/sudo", arguments: ["-n", helperPath, "version"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard version == "iremote-capture-helper 1" else { return false }
                _ = try Self.runExecutable("/usr/bin/sudo", arguments: ["-n", helperPath, "check"])
                return true
            } catch {
                return false
            }
        }.value
    }

    /// Authoritative check for the Apple Bluetooth-debug configuration
    /// profile via the privileged helper. Returns `.installed` /
    /// `.missing` when the helper answered, or `.unknown` when the
    /// helper isn't ready (so the caller can fall back to behavioural
    /// detection).
    enum HelperProfileStatus: Sendable {
        case installed
        case missing
        case unknown
    }

    func helperProfileStatus() async -> HelperProfileStatus {
        let path = captureHelperPath
        return await Self.queryHelperProfileStatus(helperPath: path)
    }

    private nonisolated static func queryHelperProfileStatus(helperPath: String) async -> HelperProfileStatus {
        await Task.detached {
            guard FileManager.default.isExecutableFile(atPath: helperPath) else { return .unknown }
            do {
                let output = try Self.runExecutable("/usr/bin/sudo", arguments: ["-n", helperPath, "profile-status"])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                switch output {
                case "installed": return .installed
                case "missing":   return .missing
                default:          return .unknown
                }
            } catch {
                return .unknown
            }
        }.value
    }

    private nonisolated static func captureHelperScript(packetLoggerPath: String) -> String {
        let packetLogger = Self.shQuote(packetLoggerPath)
        return """
        #!/bin/sh
        set -eu
        packetlogger=\(packetLogger)
        command="${1:-}"
        workdir="${2:-}"
        legacy_label="com.iremote.packetlogger"
        legacy_plist="/Library/LaunchDaemons/com.iremote.packetlogger.plist"

        valid_workdir() {
          case "$workdir" in
            /tmp/iremote-window-*|/tmp/iremote-trigger-*|/tmp/iremote-app-*|/tmp/iremote-dictate-*|/tmp/iremote-utt-*) return 0 ;;
            *) echo "invalid workdir: $workdir" >&2; return 1 ;;
          esac
        }

        console_user() {
          stat -f %Su /dev/console 2>/dev/null || echo jono
        }

        running_pid() {
          pidfile="$1/pid"
          pid="$(cat "$pidfile" 2>/dev/null || true)"
          if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            echo "$pid"
            return 0
          fi
          return 1
        }

        stop_pid() {
          dir="$1"
          pid="$(cat "$dir/pid" 2>/dev/null || true)"
          if [ -n "$pid" ]; then
            kill -INT "$pid" 2>/dev/null || true
            i=0
            while [ "$i" -lt 100 ]; do
              if ! kill -0 "$pid" 2>/dev/null; then break; fi
              sleep 0.1
              i=$((i + 1))
            done
            if kill -0 "$pid" 2>/dev/null; then
              kill -TERM "$pid" 2>/dev/null || true
              sleep 0.2
            fi
          fi
        }

        start_packetlogger() {
          dir="$1"
          outfile="$2"
          user="$(console_user)"
          mkdir -p "$dir"
          : > "$dir/packetlogger.log"
          chown -R "$user":staff "$dir" 2>/dev/null || true
          chmod 755 "$dir" 2>/dev/null || true
          trap '' HUP
          # `-o FILE` writes the binary HCI capture format the parser
          # expects. We previously tried `-s > FILE` for unbuffered output
          # via stdbuf, but `-s` is text-only and `stdbuf` is blocked by
          # PacketLogger's library-validation flag — so the output was
          # garbage and broke voice/MENU/touchpad. Stick with `-o`.
          nohup "$packetlogger" convert -b -o "$outfile" > "$dir/packetlogger.log" 2>&1 < /dev/null &
          pid=$!
          echo "$pid" > "$dir/pid"
          sleep 0.45
          if ! kill -0 "$pid" 2>/dev/null; then
            cat "$dir/packetlogger.log" 2>/dev/null || true
            exit 70
          fi
          chown -R "$user":staff "$dir" 2>/dev/null || true
          echo "$pid"
        }

        case "$command" in
          version)
            echo "iremote-capture-helper 1"
            ;;
          check)
            test -x "$packetlogger"
            ;;
          cleanup-legacy)
            /bin/launchctl bootout system/$legacy_label >/dev/null 2>&1 || true
            rm -f "$legacy_plist"
            ;;
          profile-status)
            # Authoritative check for the Apple Bluetooth-debug
            # configuration profile (PayloadIdentifier
            # `com.apple.bluetooth.logging`). System-scoped profiles
            # are invisible without root, which sudo gives us here.
            # Prints `installed` or `missing` and always exits 0; the
            # Swift caller treats anything else as `unknown`.
            if /usr/bin/profiles list 2>/dev/null | grep -q "com.apple.bluetooth.logging"; then
              echo "installed"
              exit 0
            fi
            if /usr/bin/profiles -P 2>/dev/null | grep -q "com.apple.bluetooth.logging"; then
              echo "installed"
              exit 0
            fi
            if /usr/bin/profiles show 2>/dev/null | grep -q "com.apple.bluetooth.logging"; then
              echo "installed"
              exit 0
            fi
            echo "missing"
            exit 0
            ;;
          stream)
            mkdir -p /tmp/iremote-stream
            exec "$packetlogger" convert -b -s -f tr 2> /tmp/iremote-stream/packetlogger.log
            ;;
          capture)
            valid_workdir
            duration="${3:-1.5}"
            user="$(console_user)"
            mkdir -p "$workdir"
            rm -f "$workdir/remote.pklg" "$workdir/remote-opus.bin" "$workdir/remote-hid.bin" "$workdir/remote.wav" "$workdir/packetlogger.log" "$workdir/pid"
            : > "$workdir/packetlogger.log"
            chown -R "$user":staff "$workdir" 2>/dev/null || true
            chmod 755 "$workdir" 2>/dev/null || true
            nohup "$packetlogger" convert -b -o "$workdir/remote.pklg" > "$workdir/packetlogger.log" 2>&1 < /dev/null &
            pid=$!
            echo "$pid" > "$workdir/pid"
            sleep 0.35
            if ! kill -0 "$pid" 2>/dev/null; then
              cat "$workdir/packetlogger.log" 2>/dev/null || true
              exit 70
            fi
            sleep "$duration"
            kill -INT "$pid" 2>/dev/null || true
            i=0
            while [ "$i" -lt 100 ]; do
              if ! kill -0 "$pid" 2>/dev/null; then break; fi
              sleep 0.1
              i=$((i + 1))
            done
            if kill -0 "$pid" 2>/dev/null; then
              kill -TERM "$pid" 2>/dev/null || true
              sleep 0.2
            fi
            wait "$pid" 2>/dev/null || true
            chown -R "$user":staff "$workdir" 2>/dev/null || true
            ;;
          start)
            valid_workdir
            rm -f "$workdir/remote.pklg" "$workdir/remote-opus.bin" "$workdir/remote-hid.bin" "$workdir/remote.wav" "$workdir/packetlogger.log" "$workdir/pid"
            start_packetlogger "$workdir" "$workdir/remote.pklg"
            ;;
          stop)
            valid_workdir
            stop_pid "$workdir"
            user="$(console_user)"
            chown -R "$user":staff "$workdir" 2>/dev/null || true
            if [ ! -s "$workdir/remote.pklg" ]; then
              echo "remote.pklg is empty" >&2
              cat "$workdir/packetlogger.log" 2>/dev/null || true
              exit 71
            fi
            ;;
          *)
            echo "usage: $0 version|check|cleanup-legacy|profile-status|stream|capture|start|stop [workdir]" >&2
            exit 64
            ;;
        esac
        """
    }

    private nonisolated static func ensureExtractorCompiled(projectRoot: String, extractorPath: String) throws {
        if FileManager.default.isExecutableFile(atPath: extractorPath) {
            return
        }
        try FileManager.default.createDirectory(atPath: "/private/tmp/iremote-swift-cache", withIntermediateDirectories: true)
        _ = try runExecutable(
            "/usr/bin/swiftc",
            arguments: [
                "-module-cache-path",
                "/private/tmp/iremote-swift-cache",
                "\(projectRoot)/Tools/extract-remote-opus.swift",
                "-o",
                extractorPath,
            ]
        )
    }

    private nonisolated static func extractOpusFramesFromPklg(
        workDir: String,
        projectRoot: String,
        extractorPath: String
    ) throws -> [Data] {
        let pklgPath = "\(workDir)/remote.pklg"
        let opusPath = "\(workDir)/remote-opus.bin"
        let rawHidPath = "\(workDir)/remote-hid.bin"

        let pklgBytes = ((try? FileManager.default.attributesOfItem(atPath: pklgPath)[.size]) as? NSNumber)?.intValue ?? 0
        guard pklgBytes > 0 else { return [] }

        try ensureExtractorCompiled(projectRoot: projectRoot, extractorPath: extractorPath)
        let result = try runExecutableResult(extractorPath, arguments: [pklgPath, "--out", opusPath, "--raw-hid-out", rawHidPath])
        let combinedOutput = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        let opusBytes = ((try? FileManager.default.attributesOfItem(atPath: opusPath)[.size]) as? NSNumber)?.intValue ?? 0

        if opusBytes == 0 {
            if combinedOutput.contains("redacted voice PDUs:") && !combinedOutput.contains("redacted voice PDUs: 0") {
                throw RemoteDictationServiceError.failed(combinedOutput)
            }
            return []
        }

        return try readLengthPrefixedOpus(from: opusPath)
    }

    private nonisolated static func readLengthPrefixedOpus(from path: String) throws -> [Data] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var frames: [Data] = []
        var cursor = 0
        while cursor + 2 <= data.count {
            let length = (Int(data[cursor]) << 8) | Int(data[cursor + 1])
            cursor += 2
            guard length > 0, cursor + length <= data.count else { break }
            frames.append(data.subdata(in: cursor..<(cursor + length)))
            cursor += length
        }
        return frames
    }

    private nonisolated static func transcribeCapturedPklg(
        workDir: String,
        projectRoot: String,
        extractorPath: String,
        decoderPath: String,
        whisperCLIPath: String,
        whisperModelPath: String,
        language: String
    ) throws -> RemoteDictationResult {
        let pklgPath = "\(workDir)/remote.pklg"
        let opusPath = "\(workDir)/remote-opus.bin"
        let rawHidPath = "\(workDir)/remote-hid.bin"
        let wavPath = "\(workDir)/remote-raw.wav"
        let processedWavPath = "\(workDir)/remote-voice.wav"
        let whisperWavPath = "\(workDir)/remote-whisper.wav"
        let transcriptPath = "\(workDir)/transcript.txt"
        let packetLoggerLog = Self.readTextIfExists("\(workDir)/packetlogger.log")

        guard FileManager.default.fileExists(atPath: pklgPath) else {
            throw RemoteDictationServiceError.failed("No PacketLogger capture was created")
        }

        try ensureExtractorCompiled(projectRoot: projectRoot, extractorPath: extractorPath)
        try ensureDecoderCompiled(projectRoot: projectRoot, decoderPath: decoderPath)
        let extractOutput = try runExecutable(extractorPath, arguments: [pklgPath, "--out", opusPath, "--raw-hid-out", rawHidPath])
        let opusBytes = ((try? FileManager.default.attributesOfItem(atPath: opusPath)[.size]) as? NSNumber)?.intValue ?? 0
        guard opusBytes > 0 else {
            let detail = [extractOutput, packetLoggerLog].filter { !$0.isEmpty }.joined(separator: "\n")
            throw RemoteDictationServiceError.failed(detail.isEmpty ? "No Siri Remote voice frames found" : detail)
        }

        _ = try runExecutable(decoderPath, arguments: [opusPath, wavPath])
        let inputForWhisper = try prepareAudioForWhisper(
            rawWavPath: wavPath,
            cleanedWavPath: processedWavPath,
            fallbackWavPath: whisperWavPath
        )

        let rawTranscript = try runExecutable(
            whisperCLIPath,
            arguments: [
                "-m", whisperModelPath,
                "-f", inputForWhisper,
                "-l", language,
                "-t", "4",
                // GPU on (Metal): ~5x faster than CPU-only on Apple
                // Silicon for the small model. Do NOT pass -ng here.
                "-nt",
                "--no-prints",
                "--prompt", Self.punctuationPrompt,
            ]
        )
        let cleaned = cleanTranscript(rawTranscript)
        try cleaned.write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        try? publishLatestArtifacts(
            projectRoot: projectRoot,
            rawWavPath: wavPath,
            processedWavPath: inputForWhisper == wavPath ? nil : inputForWhisper,
            transcriptPath: transcriptPath,
            whisperModelPath: whisperModelPath,
            language: language,
            opusFrameCount: 0
        )
        guard !cleaned.isEmpty else {
            throw RemoteDictationServiceError.emptyTranscript("No transcript produced")
        }
        return RemoteDictationResult(
            transcript: cleaned,
            wavPath: wavPath,
            processedWavPath: inputForWhisper == wavPath ? nil : inputForWhisper,
            workDir: workDir,
            rawOutput: rawTranscript,
            opusFrameCount: 0
        )
    }

    private nonisolated static func publishLatestArtifacts(
        projectRoot: String,
        rawWavPath: String,
        processedWavPath: String?,
        transcriptPath: String,
        whisperModelPath: String,
        language: String,
        opusFrameCount: Int
    ) throws {
        let latestDir = URL(fileURLWithPath: projectRoot)
            .appendingPathComponent("build")
            .appendingPathComponent("latest-audio")
        try FileManager.default.createDirectory(at: latestDir, withIntermediateDirectories: true)

        func replaceCopy(from source: String, to name: String) throws {
            let destination = latestDir.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: source), to: destination)
        }

        try replaceCopy(from: rawWavPath, to: "remote-raw.wav")
        if let processedWavPath {
            try replaceCopy(from: processedWavPath, to: "remote-voice.wav")
            try replaceCopy(from: processedWavPath, to: "remote-lite.wav")
        }
        try replaceCopy(from: transcriptPath, to: "transcript.txt")

        let modelInfo = [
            "model=\(whisperModelPath)",
            "model_name=\(URL(fileURLWithPath: whisperModelPath).lastPathComponent)",
            "language=\(language)",
            "raw=\(rawWavPath)",
            "voice=\(processedWavPath ?? rawWavPath)",
            "voice_filter=\(Self.voiceProcessingFilter())",
            "opus_frames=\(opusFrameCount)",
        ].joined(separator: "\n") + "\n"
        try modelInfo.write(to: latestDir.appendingPathComponent("model.txt"), atomically: true, encoding: .utf8)
    }

    private nonisolated static func voiceProcessingFilter() -> String {
        [
            "adeclip=t=8",
            "highpass=f=100:p=2",
            "lowpass=f=7600:p=1",
            "afftdn=nr=7:nf=-46:tn=1:rf=-32:ad=0.35:gs=6",
            "speechnorm=p=0.88:e=1.2:c=1.6:r=0.0005:f=0.001:m=0.05",
            "volume=2.4",
            "alimiter=limit=0.92:attack=2:release=60",
            "aresample=16000",
        ].joined(separator: ",")
    }

    private nonisolated static func prepareAudioForWhisper(
        rawWavPath: String,
        cleanedWavPath: String,
        fallbackWavPath: String
    ) throws -> String {
        let ffmpeg = "/opt/homebrew/bin/ffmpeg"
        guard FileManager.default.isExecutableFile(atPath: ffmpeg) else {
            return rawWavPath
        }

        let voiceFilter = Self.voiceProcessingFilter()
        let fallbackFilter = "highpass=f=80,alimiter=limit=0.96,aresample=16000"

        do {
            _ = try runExecutable(
                ffmpeg,
                arguments: [
                    "-y", "-hide_banner", "-loglevel", "error",
                    "-i", rawWavPath,
                    "-af", voiceFilter,
                    "-ac", "1", "-ar", "16000",
                    cleanedWavPath,
                ]
            )
            return cleanedWavPath
        } catch {
            _ = try runExecutable(
                ffmpeg,
                arguments: [
                    "-y", "-hide_banner", "-loglevel", "error",
                    "-i", rawWavPath,
                    "-af", fallbackFilter,
                    "-ac", "1", "-ar", "16000",
                    fallbackWavPath,
                ]
            )
            return fallbackWavPath
        }
    }

    private nonisolated static func cleanupRollingCaptureDirs(keeping keepPath: String) {
        let tmp = URL(fileURLWithPath: "/tmp", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: tmp, includingPropertiesForKeys: nil) else { return }
        for item in items where item.lastPathComponent.hasPrefix("iremote-window-") && item.path != keepPath {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private nonisolated static func pruneUtteranceDirs(maxCount: Int) {
        let tmp = URL(fileURLWithPath: "/tmp", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: tmp,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }

        let utteranceDirs = items
            .filter { $0.lastPathComponent.hasPrefix("iremote-utt-") }
            .map { url -> (URL, Date) in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                return (url, values?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.1 > $1.1 }

        guard utteranceDirs.count > maxCount else { return }
        for item in utteranceDirs.dropFirst(maxCount) {
            try? FileManager.default.removeItem(at: item.0)
        }
    }

    private nonisolated static func readTextIfExists(_ path: String) -> String {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func ensureDecoderCompiled(projectRoot: String, decoderPath: String) throws {
        if FileManager.default.isExecutableFile(atPath: decoderPath) {
            return
        }
        _ = try runExecutable(
            "/usr/bin/clang",
            arguments: [
                "\(projectRoot)/Tools/decode-remote-opus.c",
                "-lopus",
                "-I/opt/homebrew/include",
                "-L/opt/homebrew/lib",
                "-o",
                decoderPath,
            ]
        )
    }

    private nonisolated static func writeLengthPrefixedOpus(_ frames: [Data], to path: String) throws {
        var out = Data()
        for frame in frames {
            guard frame.count <= UInt16.max else { continue }
            var length = UInt16(frame.count).bigEndian
            withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
            out.append(frame)
        }
        try out.write(to: URL(fileURLWithPath: path))
    }

    private nonisolated static func runExecutableResult(_ executable: String, arguments: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
        } catch {
            throw RemoteDictationServiceError.failed("Unable to start \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)")
        }
        task.waitUntilExit()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (task.terminationStatus, out, err)
    }

    private nonisolated static func runExecutable(_ executable: String, arguments: [String]) throws -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        do {
            try task.run()
        } catch {
            throw RemoteDictationServiceError.failed("Unable to start \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)")
        }
        task.waitUntilExit()

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard task.terminationStatus == 0 else {
            let detail = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
            throw RemoteDictationServiceError.failed(detail.isEmpty ? "\(executable) failed" : detail)
        }
        return out
    }

    private nonisolated static func runWithAdministratorPrivileges(_ shellCommand: String) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            task.arguments = [
                "-e",
                "do shell script \(appleScriptString(shellCommand)) with administrator privileges",
            ]

            let outPipe = Pipe()
            let errPipe = Pipe()
            task.standardOutput = outPipe
            task.standardError = errPipe

            do {
                try task.run()
            } catch {
                throw RemoteDictationServiceError.failed("Unable to start admin capture: \(error.localizedDescription)")
            }
            task.waitUntilExit()

            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            guard task.terminationStatus == 0 else {
                let detail = [out, err].filter { !$0.isEmpty }.joined(separator: "\n")
                throw RemoteDictationServiceError.failed(detail.isEmpty ? "Remote capture failed" : detail)
            }
            return out
        }.value
    }

    private nonisolated static func parseValue(prefix: String, in output: String) -> String? {
        output
            .components(separatedBy: .newlines)
            .first { $0.hasPrefix(prefix) }?
            .dropFirst(prefix.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func cleanTranscript(_ raw: String) -> String {
        let joined = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return normalizePunctuationForCJK(joined)
    }

    /// Replace ASCII punctuation with its CJK fullwidth equivalent
    /// whenever the punctuation sits next to a CJK character.
    /// Whisper-small often emits ASCII commas in pure-Chinese
    /// transcripts because the bilingual prompt biases punctuation
    /// tokens across writing systems; this normalisation matches each
    /// punctuation mark to the writing system of its neighbours.
    ///
    /// Rules:
    /// - Lookup table: `, . ? ! : ;` → `，。？！：；`.
    /// - Numeric separators (e.g. `3.14`, `1,000`) are skipped: if the
    ///   ASCII `,` or `.` has digits as its immediate neighbours on
    ///   both sides, it stays ASCII regardless of surrounding context.
    /// - Otherwise, look at the nearest non-whitespace character on
    ///   each side. If either side is CJK, convert to fullwidth.
    ///   Otherwise leave the ASCII char alone.
    ///
    /// This preserves pure-English output unchanged (`Hello, world.`
    /// stays as-is) and produces natural Chinese output for pure-CJK
    /// transcripts (halfwidth ASCII punctuation gets replaced with
    /// its fullwidth Chinese equivalent). Mixed text gets the CJK
    /// form when at least one neighbour is CJK, which matches the
    /// typical "Chinese punctuation around Chinese clauses"
    /// convention users expect when dictating mixed material.
    private nonisolated static func normalizePunctuationForCJK(_ text: String) -> String {
        guard !text.isEmpty else { return text }

        let map: [Character: Character] = [
            ",": "，",
            ".": "。",
            "?": "？",
            "!": "！",
            ":": "：",
            ";": "；",
        ]

        var chars = Array(text)
        for i in 0..<chars.count {
            let c = chars[i]
            guard let cjk = map[c] else { continue }

            let immediatePrev: Character? = i > 0 ? chars[i - 1] : nil
            let immediateNext: Character? = i + 1 < chars.count ? chars[i + 1] : nil

            // Decimal points / thousands separators stay ASCII even
            // in CJK contexts (e.g. a numeric literal like 3.14 in
            // an otherwise-Chinese sentence must keep its halfwidth
            // period — it's a decimal point, not a sentence ending).
            if (c == "." || c == ","),
               let p = immediatePrev, p.isNumber,
               let n = immediateNext, n.isNumber {
                continue
            }

            let leftAnchor = nearestNonWhitespace(in: chars, from: i - 1, step: -1)
            let rightAnchor = nearestNonWhitespace(in: chars, from: i + 1, step: +1)
            let leftIsCJK = leftAnchor.map(isCJK) ?? false
            let rightIsCJK = rightAnchor.map(isCJK) ?? false

            if leftIsCJK || rightIsCJK {
                chars[i] = cjk
            }
        }
        return String(chars)
    }

    private nonisolated static func nearestNonWhitespace(in chars: [Character], from start: Int, step: Int) -> Character? {
        var i = start
        while i >= 0 && i < chars.count {
            if !chars[i].isWhitespace {
                return chars[i]
            }
            i += step
        }
        return nil
    }

    private nonisolated static func isCJK(_ char: Character) -> Bool {
        for scalar in char.unicodeScalars {
            let v = scalar.value
            // CJK Unified Ideographs
            if (0x4E00...0x9FFF).contains(v) { return true }
            // CJK Extension A
            if (0x3400...0x4DBF).contains(v) { return true }
            // CJK Symbols and Punctuation (includes already-fullwidth)
            if (0x3000...0x303F).contains(v) { return true }
            // Hiragana + Katakana
            if (0x3040...0x30FF).contains(v) { return true }
            // Halfwidth / Fullwidth forms
            if (0xFF00...0xFFEF).contains(v) { return true }
            // CJK Extension B–F
            if (0x20000...0x2FFFF).contains(v) { return true }
        }
        return false
    }

    private nonisolated static func defaultWhisperModelPath() -> String {
        let cache = NSString("~/.cache/whisper").expandingTildeInPath
        return URL(fileURLWithPath: cache).appendingPathComponent("ggml-small.bin").path
    }

    private nonisolated static func isEnglishOnlyModel(_ path: String) -> Bool {
        URL(fileURLWithPath: path).lastPathComponent.contains(".en.")
    }

    private nonisolated static func shQuote(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private nonisolated static func appleScriptString(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
    }
}
