#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter_windows.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // One copy of VALUNIVO at a time: a second start brings the open window to the
  // front instead (the installer also uses this name to detect a running copy).
  HANDLE single_instance =
      ::CreateMutexW(nullptr, TRUE, L"VALUNIVO_Desktop_SingleInstance");
  if (single_instance != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"VALUNIVO");
    if (existing != nullptr) {
      ::ShowWindow(existing, ::IsIconic(existing) ? SW_RESTORE : SW_SHOW);
      ::SetForegroundWindow(existing);
    }
    ::CloseHandle(single_instance);
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  // Open centred on the main screen's work area, large enough for the computer layout
  // (side bar + page), never larger than the screen. Sizes are logical (DPI-scaled by Win32Window).
  RECT work{};
  ::SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0);
  const UINT dpi = FlutterDesktopGetDpiForMonitor(
      ::MonitorFromPoint(POINT{work.left, work.top}, MONITOR_DEFAULTTOPRIMARY));
  const int work_w = MulDiv(work.right - work.left, 96, dpi);
  const int work_h = MulDiv(work.bottom - work.top, 96, dpi);
  const int width = work_w < 1440 ? work_w - 40 : 1440;
  const int height = work_h < 900 ? work_h - 40 : 900;
  Win32Window::Point origin(MulDiv(work.left, 96, dpi) + (work_w - width) / 2,
                            MulDiv(work.top, 96, dpi) + (work_h - height) / 2);
  Win32Window::Size size(width, height);
  if (!window.Create(L"VALUNIVO", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (single_instance != nullptr) {
    ::ReleaseMutex(single_instance);
    ::CloseHandle(single_instance);
  }
  return EXIT_SUCCESS;
}
