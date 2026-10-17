#ifndef RUNNER_GAMEPAD_CHANNEL_H_
#define RUNNER_GAMEPAD_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>
#include <xinput.h>

#include <memory>

// Xbox and other XInput controllers for the "reelish/gamepad" channel.
//
// Flutter's Windows embedder reports no controller input, so the runner
// polls XInput from a window timer (|kTimerId|, every |kIntervalMs|) and
// sends "state" {buttons, lx, ly} to Dart whenever it changes. Dart turns
// that into focus navigation (lib/src/platform/desktop_gamepad.dart).
//
// Only while Reelish is the foreground window: a controller used in another
// program never drives Reelish. Empty slots are rescanned every
// |kScanIntervalMs|, since XInputGetState is slow for a slot with no
// controller. XInput is loaded at run time; without it this does nothing.
class GamepadChannel {
 public:
  static constexpr UINT_PTR kTimerId = 0x52454C;  // "REL"
  static constexpr UINT kIntervalMs = 16;
  static constexpr DWORD kScanIntervalMs = 2000;

  GamepadChannel(flutter::BinaryMessenger* messenger, HWND window);
  ~GamepadChannel();

  GamepadChannel(const GamepadChannel&) = delete;
  GamepadChannel& operator=(const GamepadChannel&) = delete;

  // Called on WM_TIMER with |kTimerId|.
  void Poll();

 private:
  using GetStateFunction = DWORD(WINAPI*)(DWORD, XINPUT_STATE*);

  void Send(int buttons, int x, int y);

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
  HMODULE xinput_ = nullptr;
  GetStateFunction get_state_ = nullptr;
  bool connected_[XUSER_MAX_COUNT] = {};
  ULONGLONG next_scan_[XUSER_MAX_COUNT] = {};
  int sent_buttons_ = 0;
  int sent_x_ = 0;
  int sent_y_ = 0;
};

#endif  // RUNNER_GAMEPAD_CHANNEL_H_
