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
A newer push waits for a running release (never cancelled half-way). **Nothing is ever published from a branch other than `main`.**

### Manual Android republish (no rebuild)
Actions → app.yml → Run workflow on `main` with `apk_from_run` (+ `apk_version`, `apk_sha256`, `web_from_run`): publishes an APK
already built and signed by an earlier run, after checking its SHA-256, version, signing certificate (= the live APK's) and that it
is newer than the live one. The web sent with it must be exactly the live web (otherwise it refuses — it would roll the web back).
Android-only: Web and Windows keep their version until the next release.

### Rehearsal (no publishing)
Run app.yml on any branch except `main` with `rehearsal` ticked: full builds, the Windows manifest signed with a throw-away key, then
`tool/release/rehearsal_test.sh` deploys with the real `remote-deploy.sh` into a throw-away server copy and verifies with the real
`verify_live.sh` (+ tampered / corrupted files must be refused). With `apk_from_run`, the republish checks run and nothing is sent.
`rollback.yml` has the same `rehearsal` switch.

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
| `WINDOWS_UPDATE_SIGNING_KEY` | **new** — Ed25519 private key (PKCS#8 PEM from `openssl genpkey`). Signs the Windows manifest. Its public half is **pinned** in `app/tool/release/windows_update_public_keys.txt` (committed); every Windows build trusts exactly those key(s) and a release stops if the secret is not one of them. |
| `ANDROID_KEYSTORE_B64`, `ANDROID_KEY_PASS` | existing — APK signing |
| `HOSTINGER_SSH_KEY` or `HOSTINGER_SSH_PASSWORD` | existing — deploy |
| `WINDOWS_CERT_PFX_B64`, `WINDOWS_CERT_PASS` | optional — Authenticode code signing (removes the SmartScreen warning; the helper then requires every update to come from the same publisher) |

Repository variable (not secret): `API_BASE_URL` (existing).

## Update signing key — security notes
- **Pinned:** the app trusts only the public key(s) committed in `windows_update_public_keys.txt`, compiled in at build time.
  Replacing the secret alone cannot change what installed apps trust (the release stops instead).
- **Private key** exists only in the GitHub secret and your offline backup. In CI it is written to a private temp file
  (`umask 077`, outside the workspace), used, and deleted (also on failure); it is never printed, committed or uploaded, and the
  release job checks the release files contain no private key.
- **Format:** OpenSSL ≥ 1.1.1 / 3.x `genpkey -algorithm ed25519` (PKCS#8 PEM). The app uses the raw 32-byte public key (base64,
  44 chars). OpenSSH-format keys (`ssh-keygen`) are refused. Windows line endings in the secret are tolerated.
- **Order of trust in the app:** signature first; nothing in the manifest is used (not even the version) before it verifies.
  The installer name is checked against a strict pattern and the URL is built from the fixed HTTPS base — a manifest cannot
  point to another site, path or file type. The installer runs only after its size + SHA-256 match the signed values (checked
  again by the helper), and the helper runs nothing else.
- **Rotation (planned):** add the new public key as a second line → release (apps now trust both) → switch the secret to the
  new private key → after everyone updated, remove the old line in a later release.
- **Lost key:** installed Windows apps can no longer update automatically. Recovery: new key + pinned public key, release, and
  each PC installs once by hand from `https://jaurea.com/valunivo/windows/VALUNIVO-Setup.exe`.
- **Stolen key:** together with write access to `jaurea.com/valunivo/windows/`, it could push code to every PC. Act at once:
  new key, remove the old line, release, ask PCs to reinstall; rotate the Hostinger credentials too. Authenticode code signing
  (optional secrets) adds a second, independent check in the helper (same publisher required).

### Backing up the private key (offline)
1. Create it on a trusted PC: `openssl genpkey -algorithm ed25519 -out valunivo-update-key.pem`.
2. Get the public half for the repository: `bash app/tool/release/public_key.sh valunivo-update-key.pem` (44 characters).
3. Paste the whole `.pem` into the secret `WINDOWS_UPDATE_SIGNING_KEY`.
4. Make 2 offline copies (e.g. two USB sticks kept in different places), optionally encrypted:
   `openssl pkey -in valunivo-update-key.pem -aes256 -out valunivo-update-key.enc.pem` (password kept separately).
5. Delete the plain file from the PC and from Downloads / Recycle Bin. Never email it, never put it in the repository or a chat.

## Rolling back
`rollback.yml` (manual, on `main`, type `ROLLBACK`): puts release `1.0.X` back from its GitHub release — the web build, and
for Windows a new signed manifest marked `rollback` pointing at that installer. **Android cannot go back** (Android refuses a
lower version): revert the change on `main` and release again.

## First real release
1. Create the key and its backups as above (steps 1–5).
2. Commit its **public** half (one line) to `app/tool/release/windows_update_public_keys.txt` — or send it to be committed.
3. Approve the merge to `main`. The pipeline builds, checks and publishes all three.
4. Windows PCs with a build from before automatic updates (1.0.4 test build): install once from
   `https://jaurea.com/valunivo/windows/VALUNIVO-Setup.exe`; from then on updates are automatic.
