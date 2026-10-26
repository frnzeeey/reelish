#include "flutter_window.h"

#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <optional>

#include "flutter/generated_plugin_registrant.h"

namespace {

// Where the window's last placement is kept between launches.
constexpr wchar_t kSettingsKey[] = L"Software\\frnzeeey\\Reelish";
constexpr wchar_t kPlacementValue[] = L"WindowPlacement";

// Smallest window, in logical pixels, that the TV interface lays out in.
constexpr int kMinWidth = 960;
constexpr int kMinHeight = 600;

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  window_channel_ =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), "reelish/window",
          &flutter::StandardMethodCodec::GetInstance());
  window_channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() == "setFullscreen") {
          const auto* value = std::get_if<bool>(call.arguments());
          if (value == nullptr) {
            result->Error("bad_args", "Expected a bool.");
            return;
          }
          SetFullscreen(*value);
          result->Success(flutter::EncodableValue(fullscreen_));
        } else if (call.method_name() == "isFullscreen") {
          result->Success(flutter::EncodableValue(fullscreen_));
        } else if (call.method_name() == "keepDisplayOn") {
          // While video plays: no display sleep or screensaver. The request
          // belongs to this (the platform) thread, where every call of this
          // channel arrives, and ends with the process.
          const auto* value = std::get_if<bool>(call.arguments());
          if (value == nullptr) {
            result->Error("bad_args", "Expected a bool.");
            return;
          }
          ::SetThreadExecutionState(
              *value ? (ES_CONTINUOUS | ES_DISPLAY_REQUIRED) : ES_CONTINUOUS);
          result->Success();
        } else {
          result->NotImplemented();
        }
      });

  app_update_channel_ = std::make_unique<AppUpdateChannel>(
      flutter_controller_->engine()->messenger(), GetHandle());
  gamepad_channel_ = std::make_unique<GamepadChannel>(
      flutter_controller_->engine()->messenger(), GetHandle());

  RestorePlacement();

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    ::ShowWindow(GetHandle(),
                 start_maximized_ ? SW_SHOWMAXIMIZED : SW_SHOWNORMAL);
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  // Placement is saved on WM_CLOSE: by now the window handle is gone.
  window_channel_ = nullptr;
  app_update_channel_ = nullptr;
  gamepad_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

void FlutterWindow::SetFullscreen(bool fullscreen) {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr || fullscreen == fullscreen_) {
    return;
  }
  if (fullscreen) {
    windowed_style_ = ::GetWindowLong(hwnd, GWL_STYLE);
    windowed_placement_.length = sizeof(WINDOWPLACEMENT);
    ::GetWindowPlacement(hwnd, &windowed_placement_);
    // Cover the whole monitor the window is on, taskbar included.
    MONITORINFO monitor{sizeof(MONITORINFO)};
    ::GetMonitorInfo(::MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST),
                     &monitor);
    ::SetWindowLong(hwnd, GWL_STYLE, windowed_style_ & ~WS_OVERLAPPEDWINDOW);
    const RECT& area = monitor.rcMonitor;
    ::SetWindowPos(hwnd, HWND_TOP, area.left, area.top,
                   area.right - area.left, area.bottom - area.top,
                   SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
  } else {
    ::SetWindowLong(hwnd, GWL_STYLE, windowed_style_);
    ::SetWindowPlacement(hwnd, &windowed_placement_);
    ::SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                   SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER |
                       SWP_FRAMECHANGED);
  }
  fullscreen_ = fullscreen;
}

void FlutterWindow::RestorePlacement() {
  WINDOWPLACEMENT placement{};
  DWORD size = sizeof(placement);
  if (::RegGetValue(HKEY_CURRENT_USER, kSettingsKey, kPlacementValue,
                    RRF_RT_REG_BINARY, nullptr, &placement,
                    &size) != ERROR_SUCCESS ||
      size != sizeof(placement) || placement.length != sizeof(placement)) {
    return;
  }
  // Ignore a position on a monitor that is no longer connected.
  if (::MonitorFromRect(&placement.rcNormalPosition, MONITOR_DEFAULTTONULL) ==
      nullptr) {
    return;
  }
  start_maximized_ = placement.showCmd == SW_SHOWMAXIMIZED;
  // Applies the normal-state rectangle while the window stays hidden until
  // its first frame.
  placement.showCmd = SW_HIDE;
  placement.flags = 0;
  ::SetWindowPlacement(GetHandle(), &placement);
}

void FlutterWindow::SavePlacement() {
  HWND hwnd = GetHandle();
  if (hwnd == nullptr) {
    return;
  }
  WINDOWPLACEMENT placement{sizeof(WINDOWPLACEMENT)};
  if (fullscreen_) {
    placement = windowed_placement_;
  } else if (!::GetWindowPlacement(hwnd, &placement)) {
    return;
  }
  if (placement.showCmd == SW_SHOWMINIMIZED) {
    placement.showCmd = SW_SHOWNORMAL;
  }
  ::RegSetKeyValue(HKEY_CURRENT_USER, kSettingsKey, kPlacementValue,
                   REG_BINARY, &placement, sizeof(placement));
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
    case WM_TIMER:
      if (wparam == GamepadChannel::kTimerId && gamepad_channel_) {
        gamepad_channel_->Poll();
        return 0;
      }
      break;
    case WM_CLOSE:
      SavePlacement();
      break;
    case WM_GETMINMAXINFO: {
      const double scale = FlutterDesktopGetDpiForHWND(hwnd) / 96.0;
      auto* info = reinterpret_cast<MINMAXINFO*>(lparam);
      info->ptMinTrackSize.x = static_cast<LONG>(kMinWidth * scale);
      info->ptMinTrackSize.y = static_cast<LONG>(kMinHeight * scale);
      return 0;
    }
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
