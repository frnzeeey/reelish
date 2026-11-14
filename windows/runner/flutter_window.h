#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/encodable_value.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>

#include <memory>
#include <string>

#include "app_update_channel.h"
#include "gamepad_channel.h"
#include "win32_window.h"

// WM_COPYDATA tag for a watch party invitation that a second launch hands to
// the Reelish window already open (main.cpp).
constexpr ULONG_PTR kPartyLinkMessage = 0x52454C4B;  // "RELK"

// The longest invitation accepted: reelish://party/ and an 8-digit code,
// with room to spare. Dart checks the code itself (PartyLinks).
constexpr size_t kMaxPartyLinkLength = 64;

// Whether |link| looks like a watch party invitation.
inline bool IsPartyLink(const std::string& link) {
  return link.size() <= kMaxPartyLinkLength &&
         link.rfind("reelish://party/", 0) == 0;
}

// A window that hosts a Flutter view, plus Reelish's desktop window
// handling: fullscreen (the "reelish/window" channel), a minimum size, and
// the window's size, position and maximized state restored across launches.
// Watch party invitations reach Dart on the "reelish/links" channel.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

  // The invitation Reelish was started with, handed to Dart once.
  void SetLaunchLink(std::string link) { launch_link_ = std::move(link); }

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

  // Watch party invitations ("reelish/links").
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      links_channel_;
  std::string launch_link_;

  bool fullscreen_ = false;
  bool start_maximized_ = false;
  LONG windowed_style_ = 0;
  WINDOWPLACEMENT windowed_placement_{sizeof(WINDOWPLACEMENT)};
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
