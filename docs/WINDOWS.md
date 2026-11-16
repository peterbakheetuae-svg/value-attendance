# VALUNIVO — Windows desktop app

A native Flutter Windows build of the same `app/` source as Web and Android: same screens, design system,
API (`API_BASE_URL`), roles, permissions and database. No WebView, no browser, no Electron.

## Build & publish (independent of Web / Android)
`.github/workflows/windows.yml` — **manual only** (Actions → Run workflow). `app.yml` (Web + Android) is not touched and never runs it.
Version: `1.0.<windows.yml run number>` — the Windows app's own numbering.

Every run (`windows-2022` / Visual Studio 2022, Flutter 3.38.10): tests → Windows smoke test → `VALUNIVO.exe` + `VALUNIVO-Updater.exe`
→ package check → launch → installer → install / shortcuts / uninstall test → (default) the real in-app update end-to-end test.

`publish` (main only, and only when the update test passed): signs the manifest with the pinned release key, copies **only**
the installer + `latest.json` to `jaurea.com/valunivo/windows/` with `remote-deploy-windows.sh` (it fails if anything outside
that folder changed), verifies it live, keeps a permanent copy as release `windows-v<version>` (never marked "latest").
`rollback_to` (main only): a signed rollback manifest pointing at an earlier installer.

Local build on a Windows PC (Visual Studio 2022 with "Desktop development with C++", Inno Setup 6):
```powershell
cd app
flutter pub get
flutter build windows --release --dart-define=API_BASE_URL=https://valunivo.vercel.app
iscc /DAppVersion=1.0.0 windows_installer\valunivo.iss
```
(a build without `--dart-define=UPDATE_PUBLIC_KEY=…` has automatic updates switched off)

## Installer
Per-user install to `%LOCALAPPDATA%\Programs\VALUNIVO` (no admin prompt), Start-menu + desktop shortcuts,
entry in "Apps & features" with uninstall. The fixed `AppId` lets every new installer update the existing copy in place.
Settings and the sign-in stay in `%APPDATA%` across updates.

## Automatic updates
1. On start and every 4 h: `https://jaurea.com/valunivo/windows/latest.json` = `{"format":1,"manifest":"…","sig":"…"}`.
   The Ed25519 signature is checked against the **pinned** key(s) compiled into the app before anything in it is used.
2. Refused: wrong signature, other app / platform / channel, an older build (unless the signed manifest says `rollback`), a
   manifest older than one already seen (replay), a build that failed here before, odd names / sizes.
3. Background download (small status chip); size + SHA-256 checked while downloading; mismatch → deleted.
4. Ready → «أعد التشغيل الآن / بعدين»; nobody signed in + idle 60 s → restarts by itself; «بعدين» → installed when VALUNIVO closes.
5. The bundled helper `VALUNIVO-Updater.exe` (temporary copy) waits for VALUNIVO to close, re-checks the installer (size,
   SHA-256, version, Authenticode publisher once code-signed), backs up the app, installs silently, checks the version,
   reopens VALUNIVO and waits for it to report healthy. Any failure → backup restored, build marked failed, old version reopened.
Settings, the DPAPI sign-in and the device id (`%APPDATA%\Value Group\VALUNIVO`) are never touched.
Logs: `%LOCALAPPDATA%\VALUNIVO\updates\updater-app.log` / `updater.log`.

## Update signing key
- Secret `WINDOWS_UPDATE_SIGNING_KEY` = Ed25519 private key (PKCS#8 PEM, `openssl genpkey -algorithm ed25519`). OpenSSH-format
  keys are refused; Windows line endings are tolerated.
- Its public half is **pinned** in `app/tool/release/windows_update_public_keys.txt` (committed, not secret). Builds trust exactly
  those key(s); publish stops if the secret is not one of them — replacing the secret alone cannot change what PCs trust.
- In CI the private key is only written to a private temp file (`umask 077`, outside the workspace), used and deleted (also on
  failure); never printed, committed or uploaded; the staging is checked for key material before upload.
- The app trusts nothing in a manifest before the signature verifies; the installer name must match a strict pattern and the URL
  is built from the fixed HTTPS base (no other site / path / file type); the installer runs only after size + SHA-256 match (checked
  again by the helper), which runs nothing else.
- Planned rotation: add the new public key as a 2nd line → publish (PCs trust both) → switch the secret → later drop the old line.
- Lost key: PCs can no longer auto-update → new key + pinned key, publish, each PC installs once from `…/windows/VALUNIVO-Setup.exe`.
- Stolen key: with write access to `valunivo/windows/` it could push code to every PC → new key, drop the old line, publish,
  reinstall PCs, rotate Hostinger credentials. Authenticode signing (optional) adds an independent publisher check in the helper.

### Creating and backing up the key (offline)
1. On a trusted PC (Git Bash): `openssl genpkey -algorithm ed25519 -out valunivo-update-key.pem`
2. Public half (44 characters) → `app/tool/release/windows_update_public_keys.txt`: `bash app/tool/release/public_key.sh valunivo-update-key.pem`
3. Whole `.pem` → repository secret `WINDOWS_UPDATE_SIGNING_KEY`.
4. Two offline copies (e.g. two USB sticks, different places), optionally encrypted:
   `openssl pkey -in valunivo-update-key.pem -aes256 -out valunivo-update-key.enc.pem` (password kept separately).
5. Delete the plain file (also from Downloads / Recycle Bin). Never email it, commit it or paste it in a chat.

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
- Publisher identity for Windows itself (SmartScreen) still needs an Authenticode certificate.
- Not code-signed until `WINDOWS_CERT_PFX_B64` / `WINDOWS_CERT_PASS` secrets are added — until then SmartScreen
  shows "unknown publisher" (More info → Run anyway).
