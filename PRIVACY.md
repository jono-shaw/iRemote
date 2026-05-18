# Privacy

iRemote runs entirely on your Mac. It does **not** transmit any user data over the network at any time.

This document spells out exactly what iRemote reads, where it stores it, and what leaves your machine.

## What iRemote reads from your Mac

- **Bluetooth packet traffic.** When the listener is running, iRemote spawns Apple's `packetlogger` CLI to capture HCI-level Bluetooth packets. The captured packets are written to `/tmp/iremote-window-live/remote.pklg`. iRemote parses this file for events from the paired Siri Remote (touchpad samples, button presses, voice frames) and ignores everything else — but the raw `.pklg` does briefly contain traffic from every Bluetooth peripheral connected to your Mac. The file is overwritten and cleaned up on every listener restart and on app quit.
- **Audio captured by the Siri Remote's built-in microphone.** When you hold the Siri/mic button on the remote, the remote streams audio over BLE. iRemote extracts the Opus-encoded voice frames from the packet capture, decodes them locally, and feeds the resulting WAV to whisper.cpp for transcription. The decoded audio is written to `/tmp/iremote-utt-<UUID>/` for the duration of one utterance and removed after transcription completes. iRemote does **not** capture audio from your Mac's built-in microphone or any other audio device.
- **The macOS Accessibility tree.** To know which UI element your touchpad focus is over, iRemote queries the Accessibility hierarchy of the frontmost app via macOS's `AXUIElement` API. This is the same API any screen reader or automation tool uses. Nothing is stored or transmitted — the queries are live and discarded immediately.
- **The frontmost text field, when dictating.** After transcription, iRemote pastes the transcript into the frontmost focused text field via simulated keyboard events. iRemote does **not** read the existing contents of that field.

## What iRemote stores on disk

| Path | Contents | Lifetime |
|---|---|---|
| `~/.cache/whisper/` | Downloaded Whisper model files (`ggml-*.bin`) you've installed via the in-app model manager. | Until you delete them via the model manager. |
| `~/Library/Preferences/io.github.jono-shaw.iRemote.plist` | Standard NSUserDefaults: active Whisper model filename, touchpad calibration matrix. | Until you delete the app's preferences. |
| `/tmp/iremote-*` | Per-utterance work directories: raw `.pklg`, decoded WAV, transcript file. | One per utterance; cleaned up automatically. |
| `/tmp/iRemote-probe.log` | Rolling log of events shown in the menu's diagnostics view. | Until you quit the app. |
| `/usr/local/bin/iremote-capture-helper` | Privileged helper script that runs `packetlogger` under root. Installed once via a one-time sudo prompt; lives only on your Mac. | Until you uninstall it. |
| `/etc/sudoers.d/iremote-packetlogger` | Sudoers entry that grants your user NOPASSWD on the helper above. | Until you uninstall it. |

## What gets transmitted

The only network traffic iRemote initiates is:

- **Whisper model downloads** from `https://huggingface.co/ggerganov/whisper.cpp/`, only when you click the cloud-download icon in the model manager.
- **The Apple Developer profile page** opened in your default browser when you click "Install Bluetooth Profile…" in the menu. The actual profile download happens between Apple and your browser; iRemote never sees it.

iRemote does not phone home. It has no analytics, no crash reporting, no usage telemetry, and no auto-update mechanism. The codebase contains no networking code outside of the Whisper-model download streamer.

## Microphone permission

When you first dictate, macOS may surface a microphone-permission prompt. This is conservative — iRemote does **not** open the Mac's built-in microphone. The audio that's transcribed comes from the *remote's* microphone via the Bluetooth pipeline. macOS still treats the helper's audio pipeline as a microphone consumer in some configurations, which is why the prompt may appear. Granting the permission is safe; denying it does not affect dictation either.

## Removing iRemote and its traces

To fully uninstall:

```sh
# Quit the app first, then:
sudo rm /usr/local/bin/iremote-capture-helper
sudo rm /etc/sudoers.d/iremote-packetlogger
rm -rf ~/Library/Preferences/io.github.jono-shaw.iRemote.plist
rm -rf ~/.cache/whisper                  # only if you don't want other apps' models
rm -rf /tmp/iremote-*                    # next reboot clears /tmp anyway
sudo profiles remove -identifier com.apple.bluetooth.logging  # if you no longer need it
```

Then drag `iRemote.app` to the Trash.
