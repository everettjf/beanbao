# Quick overlay and BeanBao speech plan

## Verified on the target phone

Bridge 0.2.5 displayed a SpringBoard-owned BeanBao input panel and keyboard over Maps while Maps remained the foreground app. A physical screen capture confirmed the panel. The Bridge resumed normally after installation and SpringBoard reload.

An experimental `show_voice` mode activated the iOS keyboard's Dictate control. After the user enabled Dictation, the microphone started without opening BeanBao. A spoken “Open Settings” test produced “Two open map” in the panel. This proves that a system keyboard can accept speech there, but it is the wrong transcription backend for BeanBao. The user requested BeanBao's own speech conversion. The keyboard Dictation trigger is removed from Bridge 0.2.6 source; the Volume Down shortcut still uses the existing BeanBao app flow. Bridge 0.2.6 has not been installed on the phone because installation reloads SpringBoard and the user asked us to avoid locking the phone overnight.

## Target design

1. Triple Volume Down opens the SpringBoard overlay above the current app without switching foreground apps.
2. A BeanBao-owned microphone process records a bounded utterance after its microphone permission has been granted. SpringBoard must not become the microphone owner: its system bundle does not carry BeanBao's privacy description or permission.
3. A bundled on-device ASR engine transcribes 16 kHz mono audio. `whisper.cpp` with the multilingual `base` model is the first candidate so English and existing Chinese commands can use one model. Its model is about 142 MiB and must be packaged with version and checksum metadata; it is not a separate app installation. Benchmark latency and memory on the iPhone 11 before selecting it for release. `tiny` is a fallback only if `base` cannot meet the device budget.
4. The overlay shows an explicit recording indicator, transcript, Stop/Cancel, and Run. The user can edit the transcript before Run. The Agent receives text only after Run, and the overlay closes before the Agent observes the target app.
5. Audio is kept in a private temporary file or bounded memory buffer and removed after transcription or cancellation. No microphone audio is sent to Claude. Claude remains the action model for tasks that need it.

The existing app records audio itself but currently uses Apple's `SpeechAnalyzer`/`DictationTranscriber` on iOS 26. That is a separate Apple transcription backend, so it does not fulfill the on-device ASR target above. The Claude Messages API is not an audio transcription endpoint. BeanBao therefore needs the ASR component even when Claude is configured for task planning.

## Next implementation gates

1. Build a narrow BeanBao microphone-owner probe in the app or a signed companion process. With the phone unlocked, verify that it can begin recording while Maps stays foreground and the overlay remains visible. Do not start by attempting microphone capture inside SpringBoard.
2. Integrate `whisper.cpp` into the microphone process, package a checksum-pinned multilingual `base` model, and transcribe a known local audio fixture. Then benchmark a real 3–8 second utterance on the target phone.
3. Add authenticated local IPC for `start`, `stop`, `cancel`, and transcript/result events. Bind every recording to one overlay session and cap duration at 30 seconds.
4. Only after those gates pass, route the triple Volume Down shortcut to the overlay and run end-to-end checks from Maps and Settings. Keep single presses changing volume normally.

The current Bridge 0.2.6 source retains the verified text overlay. It does not claim automatic BeanBao speech capture or transcription yet.
