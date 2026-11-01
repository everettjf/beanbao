# Quick overlay and BeanBao speech plan

## Verified on the target phone

Bridge 0.2.5 displayed a SpringBoard-owned BeanBao input panel and keyboard over Maps while Maps remained the foreground app. A physical screen capture confirmed the panel. The Bridge resumed normally after installation and SpringBoard reload.

An experimental `show_voice` mode activated the iOS keyboard's Dictate control. After the user enabled Dictation, the microphone started without opening BeanBao. A spoken “Open Settings” test produced “Two open map” in the panel. The keyboard Dictation trigger is removed from Bridge 0.2.6 source; the Volume Down shortcut still uses the existing BeanBao app flow. Bridge 0.2.6 has not been installed on the phone because installation reloads SpringBoard and the user asked us to avoid locking the phone overnight.

The owner subsequently confirmed that Apple's speech-to-text engine is acceptable, provided BeanBao owns the recording and transcription flow instead of tapping the system keyboard's Dictate control. App 0.3.22 declares the audio background mode and was installed without a SpringBoard reload. On the iPhone 11, its recording file grew from 284,234 to 674,378 bytes over five seconds while Maps was foreground. This establishes that an already-started BeanBao recording continues behind Maps. Starting it while BeanBao is fully backgrounded, and delivering its transcript to the overlay, are not yet implemented.

## Target design

1. Triple Volume Down opens the SpringBoard overlay above the current app without switching foreground apps.
2. The BeanBao app owns the microphone and records a bounded utterance after its permission has been granted. SpringBoard remains the overlay host and does not capture audio.
3. The existing on-device `SpeechAnalyzer`/`DictationTranscriber` code transcribes the recording. Apple speech-to-text is acceptable to the owner; the keyboard Dictate route is not needed.
4. The overlay shows an explicit recording indicator, transcript, Stop/Cancel, and Run. The user can edit the transcript before Run. The Agent receives text only after Run, and the overlay closes before the Agent observes the target app.
5. Audio is kept in a private temporary file or bounded memory buffer and removed after transcription or cancellation. No microphone audio is sent to Claude. Claude remains the action model for tasks that need it.

Claude remains the task action model. No microphone audio needs to be sent to Claude.

## Next implementation gates

1. Add a session-bound local control path: SpringBoard shows the overlay, briefly foregrounds BeanBao under it to start the microphone, then restores the original app after BeanBao confirms recording began. This respects the observed background-start limitation and uses the verified background continuation path.
2. Add stop/cancel and transcript/result events between the app and overlay. Keep the recording visibly indicated, cap it at 30 seconds, and delete temporary audio after transcription.
3. Verify the foreground handoff, real spoken transcript, and task execution on the phone before routing the triple Volume Down shortcut to the overlay. Keep single presses changing volume normally.

Bridge 0.2.8 and App 0.3.24 contain an authenticated local voice-session prototype. The overlay requests a session, opens BeanBao under the panel so the app can start its microphone in the foreground, waits for a recording-ready marker, and restores the app that was originally visible. BeanBao records for up to 30 seconds or until the overlay's Stop recording button is tapped, then passes the file to its existing on-device Apple transcriber. The result returns to an editable overlay field. Closing the overlay sends a cancellation marker. The volume shortcut still uses the established app-opening path until this new path passes device acceptance.

The first pair, Bridge 0.2.7 / App 0.3.23, was installed and tested over Settings. The overlay appeared and BeanBao launched, but the ready marker was not observed before timeout. The updated Bridge 0.2.8 / App 0.3.24 pair is installed after a SpringBoard reload. It extends the readiness timeout to 25 seconds, the total session deadline to 90 seconds, and adds periodic app-side signal checks. On the unlocked phone, the updated pair started recording, restored Settings under the overlay, stopped after silence, and returned a `No speech recognized` result. A real spoken sample is still needed to verify transcription and execution.
