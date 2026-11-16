// VALUNIVO-Updater.exe — applies a downloaded VALUNIVO update after the app has closed.
//
// Started by the app (a temporary copy in %LOCALAPPDATA%\VALUNIVO\updates, so the installer can replace the
// bundled one) with the installer the app already verified against the signed manifest. This helper:
//   1. waits for VALUNIVO to close (never replaces files in use),
//   2. verifies the installer again: size, SHA-256, file version = the expected build (no downgrade unless the
//      signed manifest said rollback), and Authenticode — once the app itself is code-signed, the installer must
//      be signed by the same publisher,
//   3. backs up the installed app folder,
//   4. runs the installer silently (it only replaces program files; settings / sign-in / device id in AppData
//      are never touched),
//   5. checks the installed version, reopens VALUNIVO and waits for it to report healthy,
//   6. on ANY failure restores the backup, records the build as failed (it is not offered again) and reopens the
//      previous version.
// It runs nothing except that one verified installer. Result: result.json + updater.log in the state folder.

#include <windows.h>
#include <bcrypt.h>
#include <softpub.h>
#include <wincrypt.h>
#include <wintrust.h>

#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <string>
#include <thread>
#include <vector>

namespace fs = std::filesystem;

namespace {

std::map<std::wstring, std::wstring> g_args;
fs::path g_state;

std::string Utf8(const std::wstring& w) {
  if (w.empty()) return {};
  int n = ::WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), nullptr, 0, nullptr, nullptr);
  std::string s(static_cast<size_t>(n), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, w.data(), static_cast<int>(w.size()), s.data(), n, nullptr, nullptr);
  return s;
}

void Log(const std::string& msg) {
  SYSTEMTIME t;
  ::GetLocalTime(&t);
  char ts[32];
  std::snprintf(ts, sizeof ts, "%04d-%02d-%02d %02d:%02d:%02d ", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond);
  std::ofstream f(g_state / L"updater.log", std::ios::app | std::ios::binary);
  f << ts << msg << "\r\n";
}

std::wstring Arg(const wchar_t* k) {
  auto it = g_args.find(k);
  return it == g_args.end() ? L"" : it->second;
}

long long ArgNum(const wchar_t* k) {
  try {
    return std::stoll(Arg(k));
  } catch (...) {
    return -1;
  }
}

std::string Escape(const std::string& s) {
  std::string o;
  for (char c : s) {
    if (c == '"' || c == '\\') o += '\\';
    if (static_cast<unsigned char>(c) >= 0x20) o += c;
  }
  return o;
}

void WriteResult(const char* result, long long from, long long to, const std::string& reason) {
  std::ofstream f(g_state / L"result.json.tmp", std::ios::binary | std::ios::trunc);
  f << "{\"result\":\"" << result << "\",\"from\":" << from << ",\"to\":" << to << ",\"reason\":\"" << Escape(reason)
    << "\"}";
  f.close();
  std::error_code ec;
  fs::rename(g_state / L"result.json.tmp", g_state / L"result.json", ec);
}

std::string Sha256File(const fs::path& p) {
  BCRYPT_ALG_HANDLE alg = nullptr;
  BCRYPT_HASH_HANDLE h = nullptr;
  std::string hex;
  if (::BCryptOpenAlgorithmProvider(&alg, BCRYPT_SHA256_ALGORITHM, nullptr, 0) != 0) return hex;
  if (::BCryptCreateHash(alg, &h, nullptr, 0, nullptr, 0, 0) == 0) {
    std::ifstream f(p, std::ios::binary);
    std::vector<char> buf(1 << 20);
    bool ok = static_cast<bool>(f);
    while (ok && f) {
      f.read(buf.data(), static_cast<std::streamsize>(buf.size()));
      auto n = f.gcount();
      if (n > 0 && ::BCryptHashData(h, reinterpret_cast<PUCHAR>(buf.data()), static_cast<ULONG>(n), 0) != 0) ok = false;
    }
    unsigned char out[32];
    if (ok && ::BCryptFinishHash(h, out, sizeof out, 0) == 0) {
      static const char* d = "0123456789abcdef";
      for (unsigned char c : out) {
        hex += d[c >> 4];
        hex += d[c & 15];
      }
    }
    ::BCryptDestroyHash(h);
  }
  ::BCryptCloseAlgorithmProvider(alg, 0);
  return hex;
}

// Third version field (1.0.<build>) of a file's version resource; -1 if none.
long long FileBuild(const fs::path& p) {
  DWORD dummy = 0;
  DWORD size = ::GetFileVersionInfoSizeW(p.c_str(), &dummy);
  if (size == 0) return -1;
  std::vector<BYTE> data(size);
  if (!::GetFileVersionInfoW(p.c_str(), 0, size, data.data())) return -1;
  VS_FIXEDFILEINFO* info = nullptr;
  UINT len = 0;
  if (!::VerQueryValueW(data.data(), L"\\", reinterpret_cast<void**>(&info), &len) || info == nullptr) return -1;
  return HIWORD(info->dwFileVersionLS);
}

// Authenticode: 1 = validly signed (signer name in *subject), 0 = not signed, -1 = signature present but invalid.
int Signer(const fs::path& file, std::wstring* subject) {
  WINTRUST_FILE_INFO fi{};
  fi.cbStruct = sizeof fi;
  fi.pcwszFilePath = file.c_str();
  WINTRUST_DATA wd{};
  wd.cbStruct = sizeof wd;
  wd.dwUIChoice = WTD_UI_NONE;
  wd.fdwRevocationChecks = WTD_REVOKE_NONE;
  wd.dwUnionChoice = WTD_CHOICE_FILE;
  wd.pFile = &fi;
  wd.dwStateAction = WTD_STATEACTION_VERIFY;
  wd.dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL;
  GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
  LONG st = ::WinVerifyTrust(static_cast<HWND>(INVALID_HANDLE_VALUE), &action, &wd);
  int result = -1;
  if (st == ERROR_SUCCESS) {
    result = 1;
    CRYPT_PROVIDER_DATA* prov = ::WTHelperProvDataFromStateData(wd.hWVTStateData);
    CRYPT_PROVIDER_SGNR* sgnr = prov ? ::WTHelperGetProvSignerFromChain(prov, 0, FALSE, 0) : nullptr;
    if (sgnr && sgnr->csCertChain > 0 && sgnr->pasCertChain[0].pCert) {
      wchar_t name[512] = {};
      ::CertGetNameStringW(sgnr->pasCertChain[0].pCert, CERT_NAME_SIMPLE_DISPLAY_TYPE, 0, nullptr, name, 512);
      *subject = name;
    }
  } else if (st == TRUST_E_NOSIGNATURE || st == TRUST_E_SUBJECT_FORM_UNKNOWN || st == TRUST_E_PROVIDER_UNKNOWN) {
    result = 0;
  }
  wd.dwStateAction = WTD_STATEACTION_CLOSE;
  ::WinVerifyTrust(static_cast<HWND>(INVALID_HANDLE_VALUE), &action, &wd);
  return result;
}

bool WaitForAppToClose(DWORD pid) {
  if (pid != 0) {
    HANDLE p = ::OpenProcess(SYNCHRONIZE, FALSE, pid);
    if (p) {
      DWORD w = ::WaitForSingleObject(p, 120000);
      ::CloseHandle(p);
      if (w != WAIT_OBJECT_0) return false;
    }
  }
  // no other VALUNIVO window may still be open (the app holds this named mutex while running)
  for (int i = 0; i < 120; ++i) {
    HANDLE m = ::OpenMutexW(SYNCHRONIZE, FALSE, L"VALUNIVO_Desktop_SingleInstance");
    if (!m) return true;
    ::CloseHandle(m);
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
  }
  return false;
}

bool CopyTree(const fs::path& from, const fs::path& to, std::string* err) {
  std::error_code ec;
  fs::remove_all(to, ec);
  fs::create_directories(to, ec);
  fs::copy(from, to, fs::copy_options::recursive | fs::copy_options::overwrite_existing, ec);
  if (ec) {
    *err = ec.message();
    return false;
  }
  return true;
}

// Empties the app folder and puts the backup back (retries while Windows still holds a file).
bool Restore(const fs::path& backup, const fs::path& app, std::string* err) {
  for (int attempt = 0; attempt < 10; ++attempt) {
    std::error_code ec;
    bool clean = true;
    for (auto& e : fs::directory_iterator(app, ec)) {
      std::error_code e2;
      fs::remove_all(e.path(), e2);
      if (e2) clean = false;
    }
    if (clean) {
      fs::copy(backup, app, fs::copy_options::recursive | fs::copy_options::overwrite_existing, ec);
      if (!ec) return true;
      *err = ec.message();
    } else {
      *err = "files still in use";
    }
    std::this_thread::sleep_for(std::chrono::seconds(2));
  }
  return false;
}

HANDLE Launch(const fs::path& exe, const fs::path& dir) {
  std::wstring cmd = L"\"" + exe.wstring() + L"\"";
  STARTUPINFOW si{};
  si.cb = sizeof si;
  PROCESS_INFORMATION pi{};
  if (!::CreateProcessW(exe.c_str(), cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, dir.c_str(), &si, &pi)) return nullptr;
  ::CloseHandle(pi.hThread);
  return pi.hProcess;
}

// Waits for healthy-<build> (written by the app a few seconds after its first frame). False if the app exits first.
bool WaitHealthy(HANDLE proc, long long build, int seconds) {
  const fs::path marker = g_state / (L"healthy-" + std::to_wstring(build));
  for (int i = 0; i < seconds * 2; ++i) {
    if (fs::exists(marker)) return true;
    if (proc && ::WaitForSingleObject(proc, 0) == WAIT_OBJECT_0) {
      DWORD code = 0;
      ::GetExitCodeProcess(proc, &code);
      Log("the app exited before reporting healthy (exit code " + std::to_string(code) + ")");
      return false;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(500));
  }
  Log("the app did not report healthy within " + std::to_string(seconds) + " s");
  return false;
}

void Kill(HANDLE proc) {
  if (proc && ::WaitForSingleObject(proc, 0) != WAIT_OBJECT_0) {
    ::TerminateProcess(proc, 1);
    ::WaitForSingleObject(proc, 10000);
  }
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE, _In_opt_ HINSTANCE, _In_ wchar_t*, _In_ int) {
  int argc = 0;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  for (int i = 1; argv && i + 1 < argc; i += 2) g_args[argv[i]] = argv[i + 1];
  if (argv) ::LocalFree(argv);

  g_state = Arg(L"--state-dir");
  const fs::path installer = Arg(L"--installer");
  const fs::path app = Arg(L"--app-dir");
  const std::string want_sha = Utf8(Arg(L"--sha256"));
  const long long size = ArgNum(L"--size"), from = ArgNum(L"--from-build"), to = ArgNum(L"--to-build");
  const bool relaunch = Arg(L"--relaunch") == L"1", downgrade = Arg(L"--allow-downgrade") == L"1";
  if (g_state.empty() || installer.empty() || app.empty() || want_sha.size() != 64 || size <= 0 || from < 0 || to <= 0) return 2;
  std::error_code ec;
  fs::create_directories(g_state, ec);
  const fs::path exe = app / L"VALUNIVO.exe";
  const fs::path backup = g_state / L"rollback";
  Log("---- update " + std::to_string(from) + " -> " + std::to_string(to) + (relaunch ? " (relaunch)" : " (on close)"));

  auto give_up = [&](const std::string& why, bool restore, bool mark_failed = true) -> int {
    Log("FAILED: " + why);
    bool restored = false;
    if (restore) {
      std::string err;
      restored = Restore(backup, app, &err);
      Log(restored ? "previous version restored from backup" : "RESTORE FAILED: " + err);
    }
    if (mark_failed) {
      std::ofstream f(g_state / L"failed-builds.txt", std::ios::app);
      f << to << "\n";
    }
    WriteResult(restore ? (restored ? "rolled_back" : "restore_failed") : "not_applied", from, to, why);
    if (relaunch) {
      fs::remove(g_state / (L"healthy-" + std::to_wstring(from)), ec);
      HANDLE p = Launch(exe, app);
      Log(p && WaitHealthy(p, from, 90) ? "previous version running and healthy" : "previous version did not report healthy");
      if (p) ::CloseHandle(p);
    }
    return 1;
  };

  // 1. VALUNIVO must be closed before anything is replaced
  if (!WaitForAppToClose(static_cast<DWORD>(ArgNum(L"--pid")))) return give_up("VALUNIVO did not close", false, false);

  // 2. the installer: exactly the verified file, the expected build, and (once code-signed) the same publisher
  if (!fs::exists(installer) || static_cast<long long>(fs::file_size(installer, ec)) != size) return give_up("installer missing or wrong size", false);
  const std::string got_sha = Sha256File(installer);
  if (got_sha != want_sha) return give_up("installer SHA-256 mismatch (" + got_sha + ")", false);
  const long long inst_build = FileBuild(installer);
  if (inst_build != to) return give_up("installer is build " + std::to_string(inst_build) + ", expected " + std::to_string(to), false);
  if (to <= from && !downgrade) return give_up("refusing to downgrade without a signed rollback manifest", false);
  std::wstring app_signer, inst_signer;
  const int app_sig = Signer(exe, &app_signer), inst_sig = Signer(installer, &inst_signer);
  if (inst_sig < 0) return give_up("installer has an invalid Authenticode signature", false);
  if (app_sig == 1) {
    if (inst_sig != 1 || inst_signer != app_signer) return give_up("installer is not signed by the app's publisher (" + Utf8(app_signer) + ")", false);
    Log("Authenticode: installer signed by the same publisher: " + Utf8(inst_signer));
  } else {
    Log(app_sig == 0 ? "Authenticode: app is not code-signed yet — relying on the signed manifest + SHA-256"
                     : "Authenticode: app signature invalid — relying on the signed manifest + SHA-256");
  }
  Log("installer verified: sha256 " + got_sha + ", build " + std::to_string(inst_build));

  // 3. backup of the installed app
  std::string err;
  if (!CopyTree(app, backup, &err)) return give_up("could not back up the app: " + err, false);
  Log("backup made");

  // 4. install silently (program files only; AppData untouched)
  std::wstring cmd = L"\"" + installer.wstring() + L"\" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /NOCANCEL /SP- /CURRENTUSER /DIR=\"" +
                     app.wstring() + L"\" /LOG=\"" + (g_state / L"install.log").wstring() + L"\"";
  STARTUPINFOW si{};
  si.cb = sizeof si;
  PROCESS_INFORMATION pi{};
  if (!::CreateProcessW(installer.c_str(), cmd.data(), nullptr, nullptr, FALSE, 0, nullptr, g_state.c_str(), &si, &pi)) {
    return give_up("could not start the installer (" + std::to_string(::GetLastError()) + ")", true);
  }
  ::CloseHandle(pi.hThread);
  DWORD wait = ::WaitForSingleObject(pi.hProcess, 15 * 60 * 1000);
  DWORD code = 1;
  ::GetExitCodeProcess(pi.hProcess, &code);
  if (wait != WAIT_OBJECT_0) ::TerminateProcess(pi.hProcess, 1);
  ::CloseHandle(pi.hProcess);
  if (wait != WAIT_OBJECT_0 || code != 0) return give_up("installer failed (exit code " + std::to_string(code) + ")", true);
  const long long installed = FileBuild(exe);
  if (installed != to) return give_up("installed VALUNIVO.exe is build " + std::to_string(installed) + ", expected " + std::to_string(to), true);
  Log("installed build " + std::to_string(installed));

  // 5. reopen and wait for the new version to report healthy
  if (relaunch) {
    fs::remove(g_state / (L"healthy-" + std::to_wstring(to)), ec);
    HANDLE p = Launch(exe, app);
    if (!p) return give_up("could not start the updated app", true);
    if (!WaitHealthy(p, to, 120)) {
      Kill(p);
      ::CloseHandle(p);
      return give_up("the updated app did not start correctly", true);
    }
    ::CloseHandle(p);
    Log("updated app running and healthy");
  }

  WriteResult(relaunch ? "updated" : "updated_on_close", from, to, "");
  fs::remove_all(backup, ec);
  fs::remove(installer, ec);
  Log("done");
  return 0;
}
