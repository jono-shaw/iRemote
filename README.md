# iRemote

**Use the Apple TV Siri Remote as a wireless trackpad, button input, and dictation microphone for your Mac.**

iRemote is a menu-bar app for macOS that turns Apple Siri Remote into a useful input device for your Mac. The touchpad becomes a focus-and-click navigator for the system UI, the MENU button toggles the iRemote menu, and the Siri/microphone button captures audio that's transcribed locally with [whisper.cpp](https://github.com/ggerganov/whisper.cpp) and pasted into the focused app.

> **Status:** v1.0.0 — first public release. Tested on macOS 26 (Tahoe) on Apple Silicon with the 1st-generation Apple TV Siri Remote.

---

## Features

- **Touchpad → focus navigator.** Slide your finger across the remote's touchpad to move a focus indicator across the screen. UI elements light up as you pass over them; click the touchpad to activate the highlighted control. Single, double, and triple clicks are all supported.
- **MENU button → iRemote menu.** Press the MENU button on the remote to toggle the iRemote menu-bar menu. No need to reach for the cursor.
- **Siri/mic button → local dictation.** Hold the Siri button to record; release to transcribe. Audio is decoded from the BLE stream and transcribed entirely on-device using whisper.cpp. The transcript is pasted into the frontmost text field.
- **Multilingual dictation.** Whisper handles ~99 languages. iRemote ships an extra Mandarin punctuation prompt that significantly improves Chinese transcription quality, plus an automatic punctuation-normalisation pass that produces fullwidth punctuation in Chinese contexts and halfwidth punctuation in English contexts — no manual switching.
- **Whisper model manager.** A built-in window lets you download additional Whisper models from Hugging Face (tiny / base / small / medium / large-v3 / large-v3-turbo / English-only variants), switch the active model on the fly, and delete unused ones.
- **Live Bluetooth-access status.** The menu shows whether iRemote is currently receiving BLE traffic from the remote and surfaces a one-click affordance to install the Apple Bluetooth Logging Profile if it's missing (see [Setup](#setup) below).
- **Touchpad calibration.** A built-in calibration flow learns the orientation of your remote so the touchpad axes match your screen, regardless of how you hold the remote.

---

## Requirements

### Hardware

- An Apple Silicon Mac running **macOS 14 (Sonoma)** or later.
- An **Apple TV Siri Remote (1st generation)** — the silver one with a touchpad on the top half.
  - 2nd generation and later remotes are not currently supported; they use a different BLE protocol that this project does not decode. Future updates will support them.
- The remote must be paired to your Mac in System Settings → Bluetooth like any other Bluetooth peripheral.

### Software

| Dependency | Why | How to get it |
|---|---|---|
| **macOS 14+** | Modern AppKit + AX APIs used by the focus driver. | Built-in. |
| **PacketLogger** | Apple's Bluetooth packet-capture CLI; how iRemote sees the remote's BLE traffic. | Bundled with Apple's [Additional Tools for Xcode](https://developer.apple.com/download/all/?q=additional%20tools). Install the `.dmg`, then drag `PacketLogger.app` to `/Applications/` (or `~/Downloads/`, `~/Applications/` — iRemote searches all four). |
| **whisper.cpp `whisper-cli`** | Local transcription. | `brew install whisper-cpp` (Apple Silicon: `/opt/homebrew/bin/whisper-cli`). |
| **Bluetooth Logging Profile** | Apple's diagnostic profile that grants PacketLogger access to private BLE traffic. **Without it iRemote cannot see remote events.** | iRemote opens [Apple's direct download link](https://developer.apple.com/services-account/download?path=/OS_X/OS_X_Logs/Bluetooth_macOS.mobileconfig) for you when the profile is missing — just click "Install Bluetooth Profile…" in the iRemote menu. Sign in with your Apple ID, the download starts automatically, then approve the install in System Settings → Privacy & Security → Profiles. |

---

## Install

### Option A — download a release build

1. Grab the latest `iRemote-vX.Y.Z.dmg` from the [Releases](https://github.com/jono-shaw/iRemote/releases) page.
2. Drag `iRemote.app` to your `/Applications/` folder.
3. Launch it. The icon appears in your menu bar.

The build is ad-hoc signed (not notarized). The first launch may prompt Gatekeeper; right-click the app and choose **Open**, then **Open** again on the confirmation dialog.

### Option B — build from source

See [BUILDING.md](BUILDING.md).

---

## Setup

The first time you launch iRemote, walk through the four prerequisites:

1. **Pair the remote.** System Settings → Bluetooth → put the Siri Remote into pairing mode (hold MENU + Volume Up for ~5 s) → pair.
2. **Install PacketLogger.** Download "Additional Tools for Xcode" (see [Requirements](#requirements)) and drag `PacketLogger.app` into one of the searched directories.
3. **Install whisper.cpp.** `brew install whisper-cpp`.
4. **Install the Apple Bluetooth Logging Profile.** Open the iRemote menu. The "Bluetooth Access" row tells you the current state. When it reads **"Setup needed"**, hover the row — it morphs into **"Install Bluetooth Profile…"** — and click it. Your browser opens Apple's direct download URL for `Bluetooth_macOS.mobileconfig`. Sign in with your Apple ID; the download starts automatically. Approve the install in System Settings → Privacy & Security → Profiles.
   - The profile is Apple-confidential and cannot be redistributed; iRemote points you at Apple's direct-download URL instead of bundling the file.
5. **Grant Accessibility permission.** iRemote uses macOS's Accessibility APIs to read on-screen UI and post clicks. On first launch, macOS will surface a permission prompt — grant it in System Settings → Privacy & Security → Accessibility.
6. **Download a Whisper model.** On first launch, iRemote's "Manage Whisper Models…" window opens. Pick a model — **Small** is the default and the best speed/accuracy balance for most users — and click the cloud-download icon. The model is cached at `~/.cache/whisper/`.
7. **Calibrate the touchpad** (optional but recommended). iRemote menu → "Calibrate Touchpad…" → follow the on-screen instructions. Takes 10 seconds.

---

## Usage

- **Move the focus dot.** Slide your finger across the touchpad. UI elements highlight as the focus crosses them.
- **Click.** Press the touchpad. Double-click and triple-click work the same way they do with a real mouse (within macOS's standard double-click interval).
- **Open the iRemote menu.** Press the **MENU** button on the remote.
- **Dictate.** Hold the **Siri/microphone** button (the one with the icon below the touchpad). Release to transcribe. The transcript is pasted into whichever app is frontmost.
- **Switch Whisper models.** iRemote menu → "Manage Whisper Models…" → select a row → "Use Selected".
- **Pause/resume.** iRemote menu → "Pause Listener" / "Start Listener". Pausing stops the BLE capture pipeline, which fully releases the remote.

---

## Language support

Out of the box, iRemote uses Whisper's `auto` language detection. The model decides per-utterance.

- **Pure English audio** is transcribed accurately with any model size; punctuation comes out as standard ASCII.
- **Pure Mandarin audio** benefits significantly from iRemote's built-in punctuation prompt: clauses get fullwidth commas (`，`), sentence ends get fullwidth periods (`。`), and questions get fullwidth question marks (`？`).
- **Mixed English/Mandarin audio** is handled by iRemote's post-pass punctuation normaliser: punctuation marks adjacent to CJK characters become fullwidth; marks adjacent only to Latin characters stay ASCII.
- **Other languages** are transcribed by Whisper directly. Punctuation handling for languages other than English and Mandarin is whatever the underlying model produces — no extra processing.

To pin the language, set the `IREMOTE_WHISPER_LANG` environment variable before launching (e.g. `launchctl setenv IREMOTE_WHISPER_LANG es` for Spanish).

---

## Privacy

iRemote captures Bluetooth traffic and audio. It does **not** send any data off your Mac.

See [PRIVACY.md](PRIVACY.md) for the full data-handling notes.

---

## License

iRemote is released under the [MIT License](LICENSE).

Third-party components used:

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (MIT) — local transcription.
- Apple SF Symbols — built-in macOS, used under Apple's standard license.
- Apple PacketLogger (Additional Tools for Xcode) — used as an external dependency only; not bundled.
- Apple Bluetooth Logging Profile — not bundled. Users download directly from Apple.

The 1st-generation Apple TV Siri Remote is a trademark of Apple Inc. iRemote is an independent open-source project and is not affiliated with or endorsed by Apple.

---

## Contributing

Bug reports and pull requests welcome. Please open an issue first for non-trivial changes so we can discuss approach and avoid duplicated work.

See [BUILDING.md](BUILDING.md) for how to get a development build running.

---

## Acknowledgements

iRemote stands on the shoulders of:

- The [whisper.cpp](https://github.com/ggerganov/whisper.cpp) project for excellent on-device transcription.
- The macOS Bluetooth stack and Apple's PacketLogger tool for making BLE diagnostics tractable.
- Years of community reverse-engineering work on the Siri Remote's HID and BLE protocols.
