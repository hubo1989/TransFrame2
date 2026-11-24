# Security

## Reporting a vulnerability

Please report security issues privately through GitHub: open the repository's **Security** tab and choose
**Report a vulnerability**. Do not open a public issue. Include the affected version (About window), macOS version, steps to
reproduce and the impact you see. You will get an answer as soon as possible; fixes are released as a new version and credited
in the changelog unless you prefer otherwise.

Only the latest release receives security fixes.

## How TransFrame 2 handles your data

- Screenshots, recognition results, translations and history stay on your Mac unless you use a cloud engine or an image host.
- Before anything is sent to a cloud recognition or translation engine, sensitive content (API keys, private keys, card and ID
  numbers, passwords, e-mail addresses, phone numbers) is detected on the Mac and masked. Redactions you draw are always burned in.
- API keys are stored in the macOS keychain and unlocked per session.
- There is no telemetry, analytics or account. Network traffic goes only to the engines, image hosts and update feed you use.
- Release builds are signed with a Developer ID, use the Hardened Runtime, are notarized by Apple, and updates are verified with
  an EdDSA signature (Sparkle).
