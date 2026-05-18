import Foundation

/// One Siri Remote touchpad sample as decoded from a 13-byte BLE handle
/// 0x0023 notification: positions are big-endian uint16 (0..65535),
/// `pressure == 0` means the finger has been lifted, and `isClicked`
/// is bit 7 of byte 1 — set while the touchpad's clickpad is physically
/// depressed.
struct RemoteTouchpadSample: Sendable {
    let x: UInt16
    let y: UInt16
    let pressure: UInt16
    let isClicked: Bool
    var isTouching: Bool { pressure > 0 }
}

final class RemotePklgVoiceMonitor {
    private struct InflightPDU {
        var attHandle: UInt16
        var pduTotalLen: Int
        var valueExpected: Int
        var valueTruncated: Int
        var collected: Data
    }

    private static let voiceAttHandle: UInt16 = 0x0023
    private static let hidReportLength = 101
    private static let voicePacketLengthOffset = 6
    private static let voicePacketPayloadOffset = 7

    private let filePath: String
    private var cursor = 0
    private var inflight: [UInt16: InflightPDU] = [:]
    private var task: Task<Void, Never>?
    private var lastObservedByteCount = 0

    init(filePath: String, startAtEnd: Bool = true) {
        self.filePath = filePath
        if startAtEnd,
           let size = (try? FileManager.default.attributesOfItem(atPath: filePath)[.size]) as? NSNumber {
            self.cursor = size.intValue
            self.lastObservedByteCount = size.intValue
        }
    }

    /// Starts polling the pklg file. Three event categories on handle 0x0023:
    /// - Voice frames (~101 bytes, byte0 unconstrained): `onFrame` with the
    ///   extracted Opus payload (legacy behaviour).
    /// - Button reports (2 bytes, byte0 == 0x00): `onButton(code)` where code
    ///   is byte 1 (0x20 = MENU pressed, 0x00 = released).
    /// - Touchpad reports (13 bytes, byte0 == 0x01): `onTouchpad(sample)`.
    func start(
        onBytes: ((Int) -> Void)? = nil,
        onFrame: @escaping (Data) -> Void,
        onButton: (@Sendable (UInt8) -> Void)? = nil,
        onTouchpad: (@Sendable (RemoteTouchpadSample) -> Void)? = nil
    ) {
        stop()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            while !Task.isCancelled {
                self?.readAvailableFrames(
                    onBytes: onBytes,
                    onFrame: onFrame,
                    onButton: onButton,
                    onTouchpad: onTouchpad
                )
                try? await Task.sleep(nanoseconds: 8_000_000)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func readAvailableFrames(
        onBytes: ((Int) -> Void)?,
        onFrame: (Data) -> Void,
        onButton: ((UInt8) -> Void)? = nil,
        onTouchpad: ((RemoteTouchpadSample) -> Void)? = nil
    ) {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
            return
        }

        if data.count != lastObservedByteCount {
            lastObservedByteCount = data.count
            onBytes?(data.count)
        }

        if cursor > data.count {
            cursor = 0
            inflight.removeAll()
        }

        while cursor + 13 <= data.count {
            let len = Int(Self.be32(data, cursor))
            guard len >= 9, cursor + 4 + len <= data.count else {
                break
            }

            let packetType = data[cursor + 12]
            let payloadStart = cursor + 13
            let payloadEnd = cursor + 4 + len

            if packetType == 0x03 {
                let payload = data.subdata(in: payloadStart..<payloadEnd)
                parseACL(payload, onFrame: onFrame, onButton: onButton, onTouchpad: onTouchpad)
            }

            cursor += 4 + len
        }
    }

    private func parseACL(
        _ payload: Data,
        onFrame: (Data) -> Void,
        onButton: ((UInt8) -> Void)? = nil,
        onTouchpad: ((RemoteTouchpadSample) -> Void)? = nil
    ) {
        guard payload.count >= 4 else { return }

        let handleField = Self.le16(payload, 0)
        let connHandle = handleField & 0x0fff
        let pbFlag = (handleField >> 12) & 0x3
        let aclLenWire = Int(Self.le16(payload, 2))
        let aclDataAvailable = max(0, payload.count - 4)
        let aclData = payload.subdata(in: 4..<(4 + min(aclLenWire, aclDataAvailable)))

        if pbFlag == 0b10 {
            parseACLStart(aclData, connHandle: connHandle, aclLenWire: aclLenWire,
                          onFrame: onFrame, onButton: onButton, onTouchpad: onTouchpad)
        } else if pbFlag == 0b01 {
            parseACLContinuation(aclData, connHandle: connHandle,
                                  onFrame: onFrame, onButton: onButton, onTouchpad: onTouchpad)
        }
    }

    private func parseACLStart(
        _ aclData: Data,
        connHandle: UInt16,
        aclLenWire: Int,
        onFrame: (Data) -> Void,
        onButton: ((UInt8) -> Void)? = nil,
        onTouchpad: ((RemoteTouchpadSample) -> Void)? = nil
    ) {
        guard aclData.count >= 7 else { return }

        let l2capLen = Int(Self.le16(aclData, 0))
        let l2capCID = Self.le16(aclData, 2)
        guard l2capCID == 0x0004 else { return }

        let opcode = aclData[4]
        let attHandle = Self.le16(aclData, 5)
        guard opcode == 0x1b || opcode == 0x1d else { return }

        let valueExpected = max(0, l2capLen - 3)
        let wireValueInStart = max(0, aclLenWire - 4 - 3)
        let actualValueInStart = max(0, aclData.count - 7)
        let truncated = max(0, wireValueInStart - actualValueInStart)
        let value = actualValueInStart > 0
            ? aclData.subdata(in: 7..<(7 + actualValueInStart))
            : Data()

        inflight[connHandle] = InflightPDU(
            attHandle: attHandle,
            pduTotalLen: l2capLen,
            valueExpected: valueExpected,
            valueTruncated: truncated,
            collected: value
        )
        completeIfReady(connHandle: connHandle, onFrame: onFrame, onButton: onButton, onTouchpad: onTouchpad)
    }

    private func parseACLContinuation(
        _ aclData: Data,
        connHandle: UInt16,
        onFrame: (Data) -> Void,
        onButton: ((UInt8) -> Void)? = nil,
        onTouchpad: ((RemoteTouchpadSample) -> Void)? = nil
    ) {
        guard var pdu = inflight[connHandle] else { return }
        pdu.collected.append(aclData)
        inflight[connHandle] = pdu
        completeIfReady(connHandle: connHandle, onFrame: onFrame, onButton: onButton, onTouchpad: onTouchpad)
    }

    private func completeIfReady(
        connHandle: UInt16,
        onFrame: (Data) -> Void,
        onButton: ((UInt8) -> Void)? = nil,
        onTouchpad: ((RemoteTouchpadSample) -> Void)? = nil
    ) {
        guard let pdu = inflight[connHandle] else { return }
        guard pdu.collected.count + pdu.valueTruncated >= pdu.valueExpected else { return }
        inflight.removeValue(forKey: connHandle)

        guard pdu.attHandle == Self.voiceAttHandle else { return }
        guard pdu.valueTruncated == 0 else { return }

        let value = pdu.collected

        // Button report: 2 bytes, byte 0 == 0x00. Byte 1 carries the button
        // code/bitmap (0x20 = MENU press, 0x00 = release).
        if value.count == 2, value[value.startIndex] == 0x00 {
            let code = value[value.startIndex + 1]
            onButton?(code)
            return
        }

        // Touchpad report: 13 bytes, byte 0 == 0x01.
        //   byte 0:     type (0x01)
        //   byte 1:     flags. Bit 7 (0x80) = clickpad currently pressed
        //               (the physical "click" of the touchpad). Other
        //               bits unknown, ignore.
        //   bytes 2-5:  timestamp uint32 LE
        //   bytes 6-7:  X uint16 BE
        //   bytes 8-9:  Y uint16 BE
        //   bytes 10-11: pressure uint16 BE (0 = finger lifted)
        //   byte 12:    sequence counter
        if value.count == 13, value[value.startIndex] == 0x01 {
            let base = value.startIndex
            let flags = value[base + 1]
            let isClicked = (flags & 0x80) != 0
            let x = (UInt16(value[base + 6]) << 8) | UInt16(value[base + 7])
            let y = (UInt16(value[base + 8]) << 8) | UInt16(value[base + 9])
            let pressure = (UInt16(value[base + 10]) << 8) | UInt16(value[base + 11])
            onTouchpad?(RemoteTouchpadSample(
                x: x,
                y: y,
                pressure: pressure,
                isClicked: isClicked
            ))
            return
        }

        // Voice frame: 101 bytes with Apple-private framing. Existing path.
        guard pdu.pduTotalLen >= 100, value.count >= Self.hidReportLength else { return }
        guard value.count > Self.voicePacketPayloadOffset else { return }

        let packetLength = Int(value[value.startIndex + Self.voicePacketLengthOffset])
        let payloadStart = value.startIndex + Self.voicePacketPayloadOffset
        let packetEnd = payloadStart + packetLength
        guard packetLength > 0, packetEnd <= value.endIndex else { return }

        onFrame(value.subdata(in: payloadStart..<packetEnd))
    }

    private static func be32(_ d: Data, _ offset: Int) -> UInt32 {
        (UInt32(d[offset]) << 24) | (UInt32(d[offset + 1]) << 16) | (UInt32(d[offset + 2]) << 8) | UInt32(d[offset + 3])
    }

    private static func le16(_ d: Data, _ offset: Int) -> UInt16 {
        UInt16(d[offset]) | (UInt16(d[offset + 1]) << 8)
    }
}
