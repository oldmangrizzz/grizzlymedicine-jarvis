# JARVIS SPKI Pin Rotation Calendar

Pins live in `security/pins_embedded.h`; egress allowlist entries are derived from that table.

## OAuth/model endpoints added for Gemini + GitHub Copilot

| Host | Use | Current leaf expiry | Rotate by |
|---|---|---:|---:|
| `accounts.google.com` | Google OAuth authorization | 2026-07-30 | 2026-07-16 |
| `oauth2.googleapis.com` | Google token + revoke | 2026-07-30 | 2026-07-16 |
| `generativelanguage.googleapis.com` | Gemini API | 2026-07-30 | 2026-07-16 |
| `github.com` | GitHub OAuth authorization + token | 2026-08-02 | 2026-07-19 |
| `api.github.com` | GitHub REST support | 2026-08-01 | 2026-07-18 |
| `api.githubcopilot.com` | Copilot API endpoint | 2026-07-02 | 2026-06-18 |

## Cadence

- Check all pinned hosts weekly.
- Rotate no later than 14 days before leaf expiry.
- Keep at least two pins per host: leaf plus intermediate/root backup.
- After rotation, run `test_egress_allowlist`, OAuth Catch2 tests, and a cert-pinning integration check before shipping.

The checked-in extractor currently uses temporary files; for this update pins were extracted with project-local scratch files and the scratch directory was removed after extraction.
