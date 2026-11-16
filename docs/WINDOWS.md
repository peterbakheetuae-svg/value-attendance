# VALUNIVO — Windows desktop app

A native Flutter Windows build of the same `app/` source as Web and Android: same screens, design system,
API (`API_BASE_URL`), roles, permissions and database. No WebView, no browser, no Electron.

## Build
Part of every release (`app.yml` → `windows.yml`, same version as Web and Android) — see [RELEASE.md](RELEASE.md).
On `feature/windows-desktop` pushes `windows.yml` also runs the in-app update end-to-end test.
Runs on `windows-2022` / Visual Studio 2022, Flutter 3.38.10.

Local build on a Windows PC (Visual Studio 2022 with "Desktop development with C++", Inno Setup 6):
```powershell
cd app
flutter pub get
flutter build windows --release --dart-define=API_BASE_URL=https://valunivo.vercel.app
iscc /DAppVersion=1.0.0 windows_installer\valunivo.iss
```
(a local build without `--dart-define=UPDATE_PUBLIC_KEY=…` has automatic updates switched off)

## Installer
Per-user install to `%LOCALAPPDATA%\Programs\VALUNIVO` (no admin prompt), Start-menu + desktop shortcuts,
entry in "Apps & features" with uninstall. The fixed `AppId` lets every new installer update the existing copy in place.
Settings and the sign-in stay in `%APPDATA%` across updates.

## Updates
Automatic, from inside the app — see [RELEASE.md](RELEASE.md) (signed manifest, background download, update helper, rollback).

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
- Update integrity: the manifest is Ed25519-signed by the release pipeline and verified in the app; the installer must match
  its signed size + SHA-256. Publisher identity for Windows itself (SmartScreen) still needs an Authenticode certificate.
- Not code-signed until `WINDOWS_CERT_PFX_B64` / `WINDOWS_CERT_PASS` secrets are added — until then SmartScreen
  shows "unknown publisher" (More info → Run anyway).
