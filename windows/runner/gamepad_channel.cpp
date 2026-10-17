#include "gamepad_channel.h"

#include <flutter/standard_method_codec.h>

#include <cstdlib>

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

// Stick axes are sent in steps of this size, so a resting stick's noise
// does not flood the channel. Dart's thresholds are far coarser.
constexpr int kStickStep = 2048;

int Quantize(SHORT value) { return (value / kStickStep) * kStickStep; }

}  // namespace

GamepadChannel::GamepadChannel(flutter::BinaryMessenger* messenger,
                               HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "reelish/gamepad",
      &flutter::StandardMethodCodec::GetInstance());
  // XInput 1.4 ships with Windows 8 and later; 9.1.0 with Windows 7.
  for (const wchar_t* name : {L"xinput1_4.dll", L"xinput9_1_0.dll"}) {
    xinput_ = ::LoadLibraryW(name);
    if (xinput_ != nullptr) {
      break;
    }
  }
  if (xinput_ != nullptr) {
    get_state_ = reinterpret_cast<GetStateFunction>(
        ::GetProcAddress(xinput_, "XInputGetState"));
  }
  if (get_state_ != nullptr) {
    ::SetTimer(window_, kTimerId, kIntervalMs, nullptr);
  }
}

GamepadChannel::~GamepadChannel() {
  ::KillTimer(window_, kTimerId);
  if (xinput_ != nullptr) {
    ::FreeLibrary(xinput_);
  }
}

void GamepadChannel::Poll() {
  if (get_state_ == nullptr) {
    return;
  }
  if (::GetForegroundWindow() != window_) {
    // Releases anything held when Reelish loses the foreground.
    Send(0, 0, 0);
    return;
  }
  const ULONGLONG now = ::GetTickCount64();
  int buttons = 0;
  SHORT x = 0;
  SHORT y = 0;
  for (DWORD slot = 0; slot < XUSER_MAX_COUNT; slot++) {
    if (!connected_[slot] && now < next_scan_[slot]) {
      continue;
    }
    XINPUT_STATE state{};
    if (get_state_(slot, &state) != ERROR_SUCCESS) {
      connected_[slot] = false;
      next_scan_[slot] = now + kScanIntervalMs;
      continue;
    }
    connected_[slot] = true;
    const XINPUT_GAMEPAD& pad = state.Gamepad;
    // Every controller can navigate: their buttons are merged, and the
    // stick pushed furthest wins.
    buttons |= pad.wButtons;
    if (std::abs(pad.sThumbLX) + std::abs(pad.sThumbLY) >
        std::abs(x) + std::abs(y)) {
      x = pad.sThumbLX;
      y = pad.sThumbLY;
    }
  }
  Send(buttons, Quantize(x), Quantize(y));
}

void GamepadChannel::Send(int buttons, int x, int y) {
  if (buttons == sent_buttons_ && x == sent_x_ && y == sent_y_) {
    return;
  }
  sent_buttons_ = buttons;
  sent_x_ = x;
  sent_y_ = y;
  channel_->InvokeMethod(
      "state", std::make_unique<EncodableValue>(EncodableMap{
                   {EncodableValue("buttons"), EncodableValue(buttons)},
                   {EncodableValue("lx"), EncodableValue(x)},
                   {EncodableValue("ly"), EncodableValue(y)},
               }));
}
