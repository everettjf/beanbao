# Device acceptance checklist

Updated November 1, 2026. The tested phone is an iPhone 11 with iOS 26.0.1, Relaxin 0.5.5, and RootHide. The owner has authorized device operation. Keep the phone unlocked and screen on during UI tests. Do not record API keys, private keys, contacts, or personal note contents.

## Verify the installed build

Run `scripts/verify_device.py --expect-bundle` with the paired SSH host, port, identity, and known-hosts options described in [installation](install-and-configure.md). Confirm Bridge, Agent, and App versions, the running Agent service, and Bridge observation. The phone's Auto-Lock setting should remain at the owner's preferred value; this checklist does not change it.

## English text requests

1. Enter **Open Settings** and tap **Start**. Require a completed status and an independently observed foreground bundle ID of `com.apple.Preferences`.
2. Repeat with **Open Contacts**, **Open Notes**, and **Open Maps**. Require matching foreground bundle IDs and no contact data access.
3. Enter **Create note: BeanBao test <unique marker>**. Require completion and the full new title in the Notes list. Use a new marker for each run.
4. With a configured Claude, OpenAI, or compatible model key, enter **Search Maps for Golden Gate Bridge**. Require both the matching marker and place card, without starting navigation. Test each model service separately; a service without a key is not a passed live model test.
5. Enter **Open Maps and send a message**. Require a clear rejection, no new task ID, and no message sent.

The current test scripts are `scripts/accept_text_device.py` and `scripts/accept_app_text_device.py`. Check the app status, Agent task and service IDs, and actual UI together. A package audit or simulated Bridge test does not replace device acceptance.

## Voice and independent operation

1. Tap **Voice input**, say **Open Maps**, and tap **Stop recording**. Review the editable transcript before tapping **Start**. Require the correct foreground app and completed Agent task. On-device English language assets may need a first-use download.
2. Enable **Quick launch**, switch to Settings, and press Volume Down once to confirm normal volume behavior. Then quickly triple press Volume Down. Require one **Ask BeanBao** panel near the bottom of the screen, a brief **Starting microphone…** state, and then **Listening… Speak now.** without tapping a microphone button. Confirm its controls respond to touch, and additional rapid Volume Down presses do not open another panel. Say **Open Contacts**, tap **Stop recording**, review the transcript, and tap **Run**. Require Contacts to be foreground and the task to complete. If the overlay times out before listening, record the displayed state and the voice-session markers.
3. Unplug USB physically and run **Open Settings** in BeanBao. Reconnect, then check that the task ID advanced, the audit contains start and completion, and Settings is in the foreground. A prior build passed this test; repeat it for this build.
4. Reboot, re-enable Relaxin as needed, confirm Agent starts automatically, and run **Open Notes** and a limited Maps search. Do not repeatedly reinstall packages if the jailbreak has not been restored.

The physical-button recording and voice-to-task flow passed over an app and from the unlocked Home screen on the tested phone. Current-build USB-disconnect and reboot recovery tests remain open. Other devices require separate validation.
