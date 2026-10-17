#ifndef RUNNER_APP_UPDATE_CHANNEL_H_
#define RUNNER_APP_UPDATE_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>

// Named mutex held while Reelish runs. The installer (windows/installer/
// reelish.iss) waits for it to disappear before replacing any file.
constexpr wchar_t kReelishAppMutex[] = L"ReelishAppMutex";

// The "reelish/app_update" channel used by the Windows updater
// (lib/src/platform/windows_installation.dart):
//
//   inspectInstaller {path}  -> {productName, companyName, version,
//                                signature: valid | unsigned | invalid},
//                               or null for a file without version info
//   freeDiskSpace {path}     -> free bytes on that volume, or null
//   launchInstaller {path, logPath}
//                            -> starts the installer with fixed arguments
//                               for this app's folder, then closes |window|
//
// Nothing from release metadata reaches a command line: Dart passes only the
// path of a file it has verified, and the arguments are built here.
class AppUpdateChannel {
 public:
  AppUpdateChannel(flutter::BinaryMessenger* messenger, HWND window);

 private:
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  HWND window_;
};

#endif  // RUNNER_APP_UPDATE_CHANNEL_H_
