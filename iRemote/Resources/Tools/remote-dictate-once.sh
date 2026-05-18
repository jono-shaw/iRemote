#!/usr/bin/env bash
set -euo pipefail

# One-shot Siri Remote dictation.
#
# Capture Remote mic audio with PacketLogger, decode the Remote Opus stream,
# transcribe locally with whisper-cli, then optionally paste the text into the
# currently focused app. This never uses the Mac microphone.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Default to /Applications/; users on Apple Silicon typically drop
# Apple's "Additional Tools for Xcode" → PacketLogger.app there.
# Override with PACKETLOGGER=... before invocation if it's installed
# elsewhere.
PACKETLOGGER="${PACKETLOGGER:-/Applications/PacketLogger.app/Contents/Resources/packetlogger}"
PACKETLOGGER_EXTRA_ARGS="${PACKETLOGGER_EXTRA_ARGS:--b}"
DURATION="${DURATION:-8}"
RUN_ID="${RUN_ID:-$(date +%s)}"
WORK_DIR="${WORK_DIR:-/tmp/iremote-dictate-$RUN_ID}"
PKLG="$WORK_DIR/remote.pklg"
OPUS_BIN="$WORK_DIR/remote-opus.bin"
RAW_HID_BIN="$WORK_DIR/remote-hid.bin"
WAV="$WORK_DIR/remote.wav"
VOICE_WAV="$WORK_DIR/remote-voice.wav"
WAV_FOR_WHISPER="$WORK_DIR/remote-whisper.wav"
TRANSCRIPT_RAW="$WORK_DIR/transcript.raw.txt"
WHISPER_STDERR="$WORK_DIR/whisper.stderr.txt"
SWIFT_CACHE="${SWIFT_CACHE:-/private/tmp/iremote-swift-cache}"
EXTRACTOR="${EXTRACTOR:-/tmp/extract-remote-opus}"
DECODER="${DECODER:-/tmp/decode-remote-opus}"
FFMPEG="${FFMPEG:-/opt/homebrew/bin/ffmpeg}"
WHISPER_CLI="${WHISPER_CLI:-/opt/homebrew/bin/whisper-cli}"
if [[ -z "${WHISPER_MODEL:-}" ]]; then
  WHISPER_MODEL="$HOME/.cache/whisper/ggml-small.bin"
fi
if [[ -z "${WHISPER_LANG:-}" ]]; then
  if [[ "$WHISPER_MODEL" == *.en.bin ]]; then
    WHISPER_LANG="en"
  else
    WHISPER_LANG="auto"
  fi
fi
WHISPER_EXTRA_ARGS="${WHISPER_EXTRA_ARGS:--ng}"
INJECT="${INJECT:-1}"
INJECT_DELAY="${INJECT_DELAY:-3}"

if [[ ! -x "$PACKETLOGGER" ]]; then
  echo "PacketLogger CLI not found: $PACKETLOGGER" >&2
  exit 1
fi
if [[ ! -x "$WHISPER_CLI" || ! -f "$WHISPER_MODEL" ]]; then
  echo "Missing whisper-cli or model: $WHISPER_CLI / $WHISPER_MODEL" >&2
  exit 1
fi

mkdir -p "$WORK_DIR" "$SWIFT_CACHE"
swiftc -module-cache-path "$SWIFT_CACHE" "$ROOT_DIR/Tools/extract-remote-opus.swift" -o "$EXTRACTOR"
clang "$ROOT_DIR/Tools/decode-remote-opus.c" -lopus -I/opt/homebrew/include -L/opt/homebrew/lib -o "$DECODER"

echo "Remote dictation."
echo "Hold the Siri/mic button on the remote and speak into the remote."
echo "Capture duration: ${DURATION}s"
echo "PacketLogger extra args: ${PACKETLOGGER_EXTRA_ARGS:-<none>}"
echo

sudo -v
packetlogger_extra_args=()
if [[ -n "$PACKETLOGGER_EXTRA_ARGS" ]]; then
  read -r -a packetlogger_extra_args <<< "$PACKETLOGGER_EXTRA_ARGS"
fi
sudo "$PACKETLOGGER" convert "${packetlogger_extra_args[@]}" -o "$PKLG" &
capture_pid=$!

sleep "$DURATION"
kill -INT "$capture_pid" 2>/dev/null || true
wait "$capture_pid" 2>/dev/null || true

sudo chown "$(id -un)":staff "$PKLG" 2>/dev/null || true

"$EXTRACTOR" "$PKLG" --out "$OPUS_BIN" --raw-hid-out "$RAW_HID_BIN"
"$DECODER" "$OPUS_BIN" "$WAV"

transcribe_wav="$WAV"
if [[ -x "$FFMPEG" ]]; then
  if "$FFMPEG" -y -hide_banner -loglevel error -i "$WAV" -af "adeclip=t=8,highpass=f=100:p=2,lowpass=f=7600:p=1,afftdn=nr=7:nf=-46:tn=1:rf=-32:ad=0.35:gs=6,speechnorm=p=0.88:e=1.2:c=1.6:r=0.0005:f=0.001:m=0.05,volume=2.4,alimiter=limit=0.92:attack=2:release=60,aresample=16000" -ac 1 -ar 16000 "$VOICE_WAV"; then
    transcribe_wav="$VOICE_WAV"
  else
    "$FFMPEG" -y -hide_banner -loglevel error -i "$WAV" -af "highpass=f=80,alimiter=limit=0.96,aresample=16000" -ac 1 -ar 16000 "$WAV_FOR_WHISPER"
    transcribe_wav="$WAV_FOR_WHISPER"
  fi
fi

read -r -a whisper_extra_args <<< "$WHISPER_EXTRA_ARGS"
if ! "$WHISPER_CLI" -m "$WHISPER_MODEL" -f "$transcribe_wav" -l "$WHISPER_LANG" -t 4 -nt --no-prints "${whisper_extra_args[@]}" >"$TRANSCRIPT_RAW" 2>"$WHISPER_STDERR"; then
  echo "Whisper failed for $transcribe_wav" >&2
  sed -n '1,120p' "$WHISPER_STDERR" >&2
  exit 1
fi

transcript="$(tr '\n' ' ' < "$TRANSCRIPT_RAW" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"

echo
echo "Transcript: $transcript"
echo "WAV: $WAV"
echo "Voice WAV: $transcribe_wav"

if [[ -z "$transcript" ]]; then
  echo "No transcript produced." >&2
  exit 1
fi

if [[ "$INJECT" == "1" ]]; then
  echo "Focus the target text field now. Injecting in ${INJECT_DELAY}s..."
  sleep "$INJECT_DELAY"
  osascript - "$transcript" <<'APPLESCRIPT'
on run argv
  set the clipboard to item 1 of argv
  tell application "System Events"
    keystroke "v" using command down
  end tell
end run
APPLESCRIPT
fi
