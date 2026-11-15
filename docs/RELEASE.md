# VALUNIVO — one release for Web, Android and Windows

One approved change on `main` → `.github/workflows/app.yml` → **one version `1.0.<run number>`** for all three:

```
build (Web + APK) ─┐
windows (EXE)  ────┴─► release-files ─► hostinger ─► github-release
```

| Step | What it does | Stops the release if |
|---|---|---|
| `build` | analyze, tests, Web (wasm) with `version.json` = 1.0.N, signed APK 1.0.N | any test / build fails, Android signing key missing |
| `windows` | `windows.yml`: tests, Windows smoke test, `VALUNIVO.exe` + `VALUNIVO-Updater.exe` 1.0.N, package check, launch, installer, install/uninstall test | any of these fails, update signing key missing |
| `release-files` | signs the Windows update manifest; checks Web, Android and Windows all say 1.0.N | key ≠ key compiled into the app, versions differ |
| `hostinger` | checks every file on the server first (APK + installer hashes), then publishes; verifies all three **live** (web `version.json`, APK hash, Windows manifest signature + installer hash) | any check fails |
| `github-release` | permanent copy of every file as release `v1.0.N` (never overwrites an existing one) | — |

Nothing after a failed step runs, so the previous release stays live. A release that exists under GitHub Releases is complete and verified.
A newer push waits for a running release (never cancelled half-way).

## Update sources (what users' apps read)

| Platform | Source | Who installs |
|---|---|---|
| Web | `https://jaurea.com/valunivo/` (unchanged) | the browser loads the new build on the next visit |
| Android | `https://jaurea.com/valunivo/android/latest.json` + APK (unchanged format; also the old `/value-attendance/android/`) | the existing in-app updater; Android always asks the person to tap Install |
| Windows | `https://jaurea.com/valunivo/windows/latest.json` (signed) + `VALUNIVO-Setup-1.0.N.exe` | automatic, in the app (below) |

## Windows automatic updates

1. On start (after ~6 s) and every 4 hours: fetch `latest.json` over HTTPS. It is `{"format":1,"manifest":"…","sig":"…"}`; the
   Ed25519 signature is verified with the public key compiled into the app **before** anything in it is used.
2. Refused: wrong signature, another app/platform/channel, an older build (no downgrade) unless the signed manifest says
   `rollback`, a manifest older than one already seen (replay), a build that failed here before, odd names / sizes.
3. Download in the background (small status chip, bottom corner). Size and SHA-256 are checked while downloading; a mismatch
   deletes the file.
4. Ready → signed in: «أعد التشغيل الآن / بعدين»; nobody signed in and no mouse/keyboard for 60 s: restarts by itself;
   «بعدين» → it is installed when VALUNIVO is closed.
5. VALUNIVO starts the bundled helper (`VALUNIVO-Updater.exe`, a temporary copy) and closes. The helper waits until VALUNIVO is
   closed, checks the installer again (size, SHA-256, version = expected build, Authenticode publisher once code-signed),
   backs up the app folder, installs silently, checks the installed version, reopens VALUNIVO and waits for it to report
   healthy.
6. Any failure → the backup is restored, the build is recorded as failed (not offered again), the previous version reopens
   and shows a short note.

Settings, the DPAPI-protected sign-in and the device id are in `%APPDATA%\Value Group\VALUNIVO` and are never touched by
an update. Logs: `%LOCALAPPDATA%\VALUNIVO\updates\updater-app.log` (app) and `updater.log` (helper).

## Secrets (values never in the code)

| Secret | Used for |
|---|---|
| `WINDOWS_UPDATE_SIGNING_KEY` | **new** — Ed25519 private key (PEM). Signs the Windows manifest; its public half is compiled into each Windows build. Never change it (installed apps only trust this key). |
| `ANDROID_KEYSTORE_B64`, `ANDROID_KEY_PASS` | existing — APK signing |
| `HOSTINGER_SSH_KEY` or `HOSTINGER_SSH_PASSWORD` | existing — deploy |
| `WINDOWS_CERT_PFX_B64`, `WINDOWS_CERT_PASS` | optional — Authenticode code signing (removes the SmartScreen warning; the helper then requires every update to come from the same publisher) |

Repository variable (not secret): `API_BASE_URL` (existing).

## Rolling back
`rollback.yml` (manual, on `main`, type `ROLLBACK`): puts release `1.0.X` back from its GitHub release — the web build, and
for Windows a new signed manifest marked `rollback` pointing at that installer. **Android cannot go back** (Android refuses a
lower version): revert the change on `main` and release again.

## First real release
1. Create the update signing key once (Git Bash on Windows, or any machine with OpenSSL 3):
   `openssl genpkey -algorithm ed25519 -out valunivo-update-key.pem`
2. GitHub → repository → Settings → Secrets and variables → Actions → New repository secret
   `WINDOWS_UPDATE_SIGNING_KEY` = the whole content of that file. Keep the file offline in a safe place (and delete other copies).
3. Merge the approved change to `main`. The pipeline builds and publishes all three.
4. Windows PCs with a build from before automatic updates (1.0.4 test build): install once from
   `https://jaurea.com/valunivo/windows/VALUNIVO-Setup.exe`; from then on updates are automatic.
