# VALUNIVO — Windows desktop app

A native Flutter Windows build of the same `app/` source as Web and Android: same screens, design system,
API (`API_BASE_URL`), roles, permissions and database. No WebView, no browser, no Electron.

## Build
`.github/workflows/windows.yml` (runs on `windows-2022` / Visual Studio 2022, Flutter 3.38.10 — same as `app.yml`):

| Branch | Builds | Publishes |
|---|---|---|
| `feature/windows-desktop` | every push | artifacts only (`VALUNIVO-windows-installer`, `VALUNIVO-windows-x64-app`) |
| `main` | first line has `[win]`, or manual run | **manual run only:** GitHub release `win-v1.0.N` (never "latest") + `jaurea.com/valunivo/windows/` |

Each run: `flutter test` → Windows smoke test inside the app (DPAPI round trip, API reachable, server rejects missing/forged token, login screen) → `flutter build windows --release` → VC++ runtime DLLs copied next to the exe →
package completeness check → launch test → Inno Setup installer → silent install / shortcuts / launch / uninstall test.

Outputs:
- `VALUNIVO-Setup-1.0.N.exe` — the installer
- `VALUNIVO-1.0.N-windows-x64.zip` — the full app folder (`VALUNIVO.exe`, `flutter_windows.dll`, plugin DLLs, `data/`)

Local build on a Windows PC (Visual Studio 2022 with "Desktop development with C++", Inno Setup 6):
```powershell
cd app
flutter pub get
flutter build windows --release --dart-define=API_BASE_URL=https://valunivo.vercel.app
iscc /DAppVersion=1.0.0 windows_installer\valunivo.iss
```

## Installer
Per-user install to `%LOCALAPPDATA%\Programs\VALUNIVO` (no admin prompt), Start-menu + desktop shortcuts,
entry in "Apps & features" with uninstall. The fixed `AppId` lets every new installer update the existing copy in place.
Settings and the sign-in stay in `%APPDATA%` across updates.

## Updates
The app checks `https://jaurea.com/valunivo/windows/latest.json` on start (and from «التحقق من التحديثات»):
`{"version","build","installer","size","sha256"}`. A newer build is downloaded, its **SHA-256 is checked**, then
the installer runs silently, updates in place and reopens the app. `latest.json` is uploaded last, so the app
never sees a version before its installer is fully there. First install link: `https://jaurea.com/valunivo/windows/VALUNIVO-Setup.exe`.

## What works on Windows
Login / logout / session, roles and permissions (enforced by the API), all pages in the website's computer layout
(glass side bar), attendance check-in/out with location (Windows location service) and webcam selfie,
file pickers, uploads, downloads/saves (Excel, PDF), PDF preview & printing, images, sounds, in-app alerts,
Windows toast notifications, in-app updates.

## Not available on Windows (same as the website)
- **Background location follow-up during the shift** (Android foreground service) — PCs don't leave the office;
  the server's geofence check still applies to every check-in.
- **Phone push (FCM)** — Windows gets notifications through the app's own polling + toasts while it is open.
- **Android-only permission screen** (over other apps / battery) and the lock-screen ringing alert.
- Image compression plugin has no Windows version: photos are sent at the webcam's medium resolution instead.

## Security
- No secrets in the app: only the public API URL (as on the web). Privileged keys stay on the server.
- Session token encrypted with Windows **DPAPI** (bound to the Windows user + an app-specific entropy) — never in plain text.
- Device binding unchanged: a Windows PC is a new device («كمبيوتر <PC name> (Windows)») and needs the same approval as an extra phone.
- Update integrity: the SHA-256 in `latest.json` catches corrupted / partial downloads, but it comes from the same server as
  the installer, so it is **not** a signature. Before Windows updates are published, add a code-signing certificate.
- Not code-signed until `WINDOWS_CERT_PFX_B64` / `WINDOWS_CERT_PASS` secrets are added — until then SmartScreen
  shows "unknown publisher" (More info → Run anyway).
