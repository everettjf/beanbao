# Quick overlay prototype

The SpringBoard Bridge can show a BeanBao input panel above another app through the authenticated `quick_overlay` operation. The panel includes an editable request field and a Run button. Run closes the panel before asking the Agent to execute, so the Agent sees the underlying app.

The `show_voice` mode focuses the field and attempts to activate the system keyboard's Dictate control. It selects only a visible, clickable `Dictate` element in the bottom quarter of the screen; if no such control is found, the field remains available for typing. Apple Dictation must be enabled by the user on the device. Dictated speech may be processed by Apple under the consent shown by iOS.

## Current verification

- Built the arm64e Bridge package and passed the package audit.
- Installed Bridge 0.2.5 on the iOS 26 test phone; the Bridge resumed after SpringBoard reload.
- Confirmed the panel and keyboard appear over Maps while Maps remains the foreground app.
- Tapping the keyboard microphone brought up the iOS “Enable Dictation?” consent prompt.
- Automatic Dictation activation and transcription in the SpringBoard panel still require a phone test after Dictation is enabled.

The Volume Down shortcut continues to open the BeanBao app and start its existing voice flow. The prototype does not change that shortcut until automatic Dictation and transcript delivery are verified on the phone.

## Next validation

1. Enable Apple Dictation on the phone through its consent prompt.
2. Unlock the phone and open Maps.
3. Send `{"op":"quick_overlay","mode":"show_voice"}` through the authenticated Bridge CLI.
4. Check that Dictation starts automatically, speech populates the BeanBao field, and Run starts an Agent task after the panel closes.
5. If these pass, route the triple Volume Down shortcut to `showAndStartDictation`, update the app's shortcut copy, rebuild, and test from Maps and Settings.
