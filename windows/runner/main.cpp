#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "app_update_channel.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

// A watch party invitation among the arguments (reelish://party/…), as
// Windows passes it when the reelish: protocol is opened; empty if none.
std::string FindPartyLink(const std::vector<std::string>& arguments) {
  for (const auto& argument : arguments) {
    if (IsPartyLink(argument)) return argument;
  }
  return std::string();
}

// Hands |link| to the Reelish window already open; true when one took it.
bool ForwardToRunningReelish(const std::string& link) {
  HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"Reelish");
  if (existing == nullptr) return false;
  DWORD process = 0;
  ::GetWindowThreadProcessId(existing, &process);
  // Lets that window come to the front, as this launch was asked for.
  ::AllowSetForegroundWindow(process);
  COPYDATASTRUCT data{};
  data.dwData = kPartyLinkMessage;
  data.cbData = static_cast<DWORD>(link.size());
  data.lpData = const_cast<char*>(link.data());
  DWORD_PTR answer = 0;
  return ::SendMessageTimeoutW(existing, WM_COPYDATA, 0,
                               reinterpret_cast<LPARAM>(&data),
                               SMTO_ABORTIFHUNG, 3000, &answer) != 0 &&
         answer == TRUE;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Held until Reelish exits: an update installer waits for it to be
  // released before replacing any file of this app.
  HANDLE app_mutex = ::CreateMutexW(nullptr, FALSE, kReelishAppMutex);

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  // An invitation opened while Reelish runs goes to that window instead of
  // starting a second Reelish.
  std::string party_link = FindPartyLink(command_line_arguments);
  if (!party_link.empty() && ForwardToRunningReelish(party_link)) {
    ::CoUninitialize();
    if (app_mutex != nullptr) {
      ::CloseHandle(app_mutex);
    }
    return EXIT_SUCCESS;
  }

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.SetLaunchLink(std::move(party_link));
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"Reelish", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (app_mutex != nullptr) {
    ::CloseHandle(app_mutex);
  }
  return EXIT_SUCCESS;
}
