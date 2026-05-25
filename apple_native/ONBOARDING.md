# JARVIS Onboarding

## First-time setup

Run the Soul Anchor ceremony once. It records the operator voice anchor first, then creates JARVIS's cold key, paper backup, and birth certificate. See `JARVISCeremony/README.md`.

## Add a family member

Open Cockpit, find **People JARVIS recognizes**, and click **Add a person**. Enter their name and relationship, hand them the Mac, let them record the script, play it back, then keep it. Robert approves with Touch ID.

Voice files stay on this Mac at `_local_voice/speakers/<uuid>.wav`. Names are not used in filenames.

## Remove a family member

Click **Remove**, type their name, and approve with Touch ID. JARVIS removes their voice file and updates the voice baseline.

## JARVIS does not recognize me

Try again in a quieter room. Speak normally, not too close to the microphone. If JARVIS still does not recognize the person, remove them and add them again.

## Privacy

Voice samples never leave the Mac. Speaker files are stored under `_local_voice`; the voice baseline checks their hashes. Biometric data is encrypted at rest by local macOS file protection and operator-controlled storage.
