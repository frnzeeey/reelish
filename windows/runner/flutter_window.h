#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>

#include "app_update_channel.h"
#include "gamepad_channel.h"
#include "win32_window.h"

// A window that hosts a Flutter view, plus Reelish's desktop window
// handling: fullscreen (the "reelish/window" channel), a minimum size, and
// the window's size, position and maximized state restored across launches.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  void SetFullscreen(bool fullscreen);
  void RestorePlacement();
  void SavePlacement();

  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel_;

  // Inspects and starts a downloaded update installer (Windows updater).
  std::unique_ptr<AppUpdateChannel> app_update_channel_;

  // Polls XInput controllers for navigation ("reelish/gamepad").
  std::unique_ptr<GamepadChannel> gamepad_channel_;

  bool fullscreen_ = false;
  bool start_maximized_ = false;
  LONG windowed_style_ = 0;
  WINDOWPLACEMENT windowed_placement_{sizeof(WINDOWPLACEMENT)};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
