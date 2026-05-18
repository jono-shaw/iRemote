// extract-remote-opus.swift
//
// Extracts Siri Remote microphone Opus frames from a PacketLogger .pklg file.
//
// This tool is remote-mic-only. It never reads the Mac microphone.
//
// It expects an unredacted PacketLogger capture. On macOS 26, bluetoothd's
// public rotating logs redact the first value bytes of HID voice notifications;
// this tool detects that case and refuses to emit unusable Opus.
//
// Build:
//   swiftc -module-cache-path /private/tmp/iremote-swift-cache \
//     Tools/extract-remote-opus.swift -o /tmp/extract-remote-opus
//
// Capture candidate:
//   sudo /Applications/PacketLogger.app/Contents/Resources/packetlogger \
//     convert -o /tmp/iremote-remote.pklg
//
// Decode:
//   /tmp/extract-remote-opus /tmp/iremote-remote.pklg --out /tmp/iremote-remote-opus.bin
//   /tmp/decode-remote-opus /tmp/iremote-remote-opus.bin /tmp/iremote-remote.wav

import Foundation

let voiceAttHandle: UInt16 = 0x0023
let hidReportLength = 101
let voicePacketLengthOffset = 6
let voicePacketPayloadOffset = 7

guard CommandLine.arguments.count >= 2 else {
    fputs("usage: extract-remote-opus <file.pklg> [--out /tmp/iremote-remote-opus.bin] [--raw-hid-out /tmp/remote-hid.bin] [--header-bytes N]\n", stderr)
    exit(2)
}

let inputPath = CommandLine.arguments[1]
var outPath = "/tmp/iremote-remote-opus.bin"
var rawHIDOutPath: String?
var forcedHeaderBytes: Int?

var args = Array(CommandLine.arguments.dropFirst(2))
while let arg = args.first {
    args.removeFirst()
    switch arg {
    case "--out":
        guard let value = args.first else {
            fputs("missing value after --out\n", stderr)
            exit(2)
        }
        outPath = value
        args.removeFirst()
    case "--raw-hid-out":
        guard let value = args.first else {
            fputs("missing value after --raw-hid-out\n", stderr)
            exit(2)
        }
        rawHIDOutPath = value
        args.removeFirst()
    case "--header-bytes":
        guard let value = args.first, let n = Int(value), n >= 0 else {
            fputs("missing or invalid value after --header-bytes\n", stderr)
            exit(2)
        }
        forcedHeaderBytes = n
        args.removeFirst()
    default:
        fputs("unknown argument: \(arg)\n", stderr)
        exit(2)
    }
}

guard let data = try? Data(contentsOf: URL(fileURLWithPath: inputPath)) else {
    fputs("failed to read \(inputPath)\n", stderr)
    exit(1)
}

FileManager.default.createFile(atPath: outPath, contents: nil)
guard let out = FileHandle(forWritingAtPath: outPath) else {
    fputs("failed to open \(outPath)\n", stderr)
    exit(1)
}
defer { try? out.close() }

var rawHIDOut: FileHandle?
if let rawHIDOutPath {
    FileManager.default.createFile(atPath: rawHIDOutPath, contents: nil)
    rawHIDOut = FileHandle(forWritingAtPath: rawHIDOutPath)
    if rawHIDOut == nil {
        fputs("failed to open \(rawHIDOutPath)\n", stderr)
        exit(1)
    }
}
defer { try? rawHIDOut?.close() }

func be32(_ d: Data, _ offset: Int) -> UInt32 {
    (UInt32(d[offset]) << 24) | (UInt32(d[offset + 1]) << 16) | (UInt32(d[offset + 2]) << 8) | UInt32(d[offset + 3])
}

func le16(_ d: Data, _ offset: Int) -> UInt16 {
    UInt16(d[offset]) | (UInt16(d[offset + 1]) << 8)
}

func appendBE16(_ value: UInt16, to handle: FileHandle) {
    var be = value.bigEndian
    try? handle.write(contentsOf: Data(bytes: &be, count: 2))
}

struct InflightPDU {
    var attHandle: UInt16
    var pduTotalLen: Int
    var valueExpected: Int
    var valueTruncated: Int
    var collected: Data
}

struct CompletedPDU {
    let attHandle: UInt16
    let totalLen: Int
    let value: Data
    let truncatedBytes: Int
}

var records = 0
var aclRecords = 0
var starts = 0
var continuations = 0
var completedVoice: [CompletedPDU] = []
var inflight: [UInt16: InflightPDU] = [:]

func completeIfReady(connHandle: UInt16) {
    guard let pdu = inflight[connHandle] else { return }
    guard pdu.collected.count + pdu.valueTruncated >= pdu.valueExpected else { return }
    inflight.removeValue(forKey: connHandle)

    guard pdu.attHandle == voiceAttHandle, pdu.pduTotalLen >= 100 else { return }
    completedVoice.append(CompletedPDU(
        attHandle: pdu.attHandle,
        totalLen: pdu.pduTotalLen,
        value: pdu.collected,
        truncatedBytes: pdu.valueTruncated
    ))
}

var cursor = 0
while cursor + 13 <= data.count {
    let len = Int(be32(data, cursor))
    if len < 9 || cursor + 4 + len > data.count {
        break
    }

    records += 1
    let packetType = data[cursor + 12]
    let payloadStart = cursor + 13
    let payloadEnd = cursor + 4 + len

    if packetType == 0x03 {
        aclRecords += 1
        let payload = data.subdata(in: payloadStart..<payloadEnd)
        if payload.count >= 4 {
            let handleField = le16(payload, 0)
            let connHandle = handleField & 0x0FFF
            let pbFlag = (handleField >> 12) & 0x3
            let aclLenWire = Int(le16(payload, 2))
            let aclDataAvailable = max(0, payload.count - 4)
            let aclData = payload.subdata(in: 4..<(4 + min(aclLenWire, aclDataAvailable)))

            if pbFlag == 0b10 {
                starts += 1
                if aclData.count >= 7 {
                    let l2capLen = Int(le16(aclData, 0))
                    let l2capCID = le16(aclData, 2)
                    if l2capCID == 0x0004 {
                        let opcode = aclData[4]
                        let attHandle = le16(aclData, 5)
                        if opcode == 0x1B || opcode == 0x1D {
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
                            completeIfReady(connHandle: connHandle)
                        }
                    }
                }
            } else if pbFlag == 0b01 {
                continuations += 1
                if var pdu = inflight[connHandle] {
                    pdu.collected.append(aclData)
                    inflight[connHandle] = pdu
                    completeIfReady(connHandle: connHandle)
                }
            }
        }
    }

    cursor += 4 + len
}

var redacted = 0
var tooShort = 0
var emitted = 0
var emittedBytes = 0

for pdu in completedVoice {
    if pdu.truncatedBytes > 0 {
        redacted += 1
        continue
    }
    guard pdu.value.count >= hidReportLength else {
        tooShort += 1
        continue
    }
    if let rawHIDOut {
        appendBE16(UInt16(pdu.value.count), to: rawHIDOut)
        try? rawHIDOut.write(contentsOf: pdu.value)
    }

    let opus: Data
    if let forcedHeaderBytes {
        guard pdu.value.count > forcedHeaderBytes else {
            tooShort += 1
            continue
        }
        opus = Data(pdu.value.dropFirst(forcedHeaderBytes))
    } else {
        guard pdu.value.count > voicePacketPayloadOffset else {
            tooShort += 1
            continue
        }
        let packetLength = Int(pdu.value[voicePacketLengthOffset])
        let packetEnd = voicePacketPayloadOffset + packetLength
        guard packetLength > 0, packetEnd <= pdu.value.count else {
            tooShort += 1
            continue
        }
        opus = pdu.value.subdata(in: voicePacketPayloadOffset..<packetEnd)
    }

    appendBE16(UInt16(opus.count), to: out)
    try? out.write(contentsOf: opus)
    emitted += 1
    emittedBytes += opus.count
}

print("records: \(records)")
print("acl records: \(aclRecords)")
print("acl starts: \(starts)")
print("acl continuations: \(continuations)")
print("voice PDUs: \(completedVoice.count)")
print("redacted voice PDUs: \(redacted)")
print("too-short voice PDUs: \(tooShort)")
print("opus frames emitted: \(emitted)")
print("opus bytes emitted: \(emittedBytes)")
if let forcedHeaderBytes {
    print("opus extraction: forced header skip \(forcedHeaderBytes) byte(s)")
} else {
    print("opus extraction: HID length byte @\(voicePacketLengthOffset), payload @\(voicePacketPayloadOffset)")
}
print("output: \(outPath)")
if let rawHIDOutPath {
    print("raw HID output: \(rawHIDOutPath)")
}

if emitted == 0 {
    if redacted > 0 {
        fputs("remote mic capture is present but redacted; no decodable Opus was emitted.\n", stderr)
    } else {
        fputs("no decodable remote mic Opus frames found.\n", stderr)
    }
    exit(1)
}
