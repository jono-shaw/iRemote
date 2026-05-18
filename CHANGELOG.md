# Changelog

All notable changes to iRemote will be documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.0.0] — 2026-05-18

First public release.

### Features

- **Touchpad navigation** — slide your finger across the Siri Remote's touchpad to drive an on-screen focus indicator across macOS UI; click the touchpad to activate the highlighted control.
- **Touchpad click stabilization** — focus point freezes briefly when finger motion settles, so the press lands on the targeted element instead of drifting off during the pre-click micro-motion.
- **Multi-click support** — single, double, and triple click are all delivered with proper `kCGMouseEventClickState`, so Finder opens files on double-click, text editors select words / paragraphs correctly, etc.
- **MENU button** — toggles the iRemote menu-bar menu.
- **Siri/microphone button → local dictation** — audio is extracted from the BLE packet stream, decoded to WAV, and transcribed by [whisper.cpp](https://github.com/ggerganov/whisper.cpp) entirely on-device. Transcript is auto-pasted into the focused text field.
- **Whisper model manager** — built-in window for downloading any of 10 catalogued Whisper models from Hugging Face, switching the active model, and deleting unused ones.
- **Mandarin + mixed-language transcription quality** — an initial Whisper prompt primes the decoder for Mandarin punctuation; an automatic post-pass normalizes punctuation between halfwidth and fullwidth based on adjacent characters' scripts.
- **Live Bluetooth-access status** — the menu surfaces whether the Apple Bluetooth Logging Profile is active. When it's missing, hovering the row morphs it into a clickable "Install Bluetooth Profile…" affordance that opens Apple's official profile-distribution page.
- **Touchpad calibration** — built-in flow that learns the orientation of your remote so the axes match your screen.
- **System-cursor sync** — the macOS cursor follows the focus indicator, so click events land where the focus appears regardless of any external mouse / trackpad activity.

[1.0.0]: https://github.com/jono-shaw/iRemote/releases/tag/v1.0.0
