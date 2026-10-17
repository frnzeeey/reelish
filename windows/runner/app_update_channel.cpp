#include "app_update_channel.h"

#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <softpub.h>
#include <wintrust.h>

#include <cstdio>
#include <string>
#include <vector>

#include "utils.h"

namespace {

using flutter::EncodableMap;
using flutter::EncodableValue;

std::wstring Utf16FromUtf8(const std::string& utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  const int length = ::MultiByteToWideChar(
      CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
      static_cast<int>(utf8.size()), nullptr, 0);
  if (length <= 0) {
    return std::wstring();
  }
  std::wstring utf16(length, L'\0');
  ::MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(),
                        static_cast<int>(utf8.size()), utf16.data(), length);
  return utf16;
}

// The string argument |key| of a map-valued call, or empty.
std::wstring PathArgument(const flutter::MethodCall<EncodableValue>& call,
                          const char* key) {
  const auto* arguments = std::get_if<EncodableMap>(call.arguments());
  if (arguments == nullptr) {
    return std::wstring();
  }
  const auto found = arguments->find(EncodableValue(key));
  if (found == arguments->end()) {
    return std::wstring();
  }
  const auto* value = std::get_if<std::string>(&found->second);
  return value == nullptr ? std::wstring() : Utf16FromUtf8(*value);
}

// An absolute path to an existing regular file, without characters that
// could break out of a quoted command-line argument.
bool IsPlainFilePath(const std::wstring& path) {
  if (path.size() < 4 || path.find(L'"') != std::wstring::npos ||
      path.find(L'\0') != std::wstring::npos || path[1] != L':' ||
      path[2] != L'\\') {
    return false;
  }
  const DWORD attributes = ::GetFileAttributesW(path.c_str());
  return attributes != INVALID_FILE_ATTRIBUTES &&
         (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

std::wstring QueryVersionString(const std::vector<BYTE>& data,
                                const wchar_t* name) {
  struct Translation {
    WORD language;
    WORD code_page;
  };
  Translation* translations = nullptr;
  UINT size = 0;
  std::vector<std::wstring> blocks;
  if (::VerQueryValueW(data.data(), L"\\VarFileInfo\\Translation",
                       reinterpret_cast<void**>(&translations), &size)) {
    for (UINT i = 0; i < size / sizeof(Translation); i++) {
      wchar_t block[32];
      swprintf(block, 32, L"%04x%04x", translations[i].language,
               translations[i].code_page);
      blocks.push_back(block);
    }
  }
  blocks.push_back(L"040904b0");
  blocks.push_back(L"040904e4");
  for (const auto& block : blocks) {
    const std::wstring query = L"\\StringFileInfo\\" + block + L"\\" + name;
    wchar_t* value = nullptr;
    UINT length = 0;
    if (::VerQueryValueW(data.data(), query.c_str(),
                         reinterpret_cast<void**>(&value), &length) &&
        length > 0 && value != nullptr) {
      return std::wstring(value);
    }
  }
  return std::wstring();
}

// "valid" for a signature that verifies, "unsigned" for no signature, and
// "invalid" for one that is present but does not verify (tampered, expired
// or untrusted). Revocation is not checked online.
std::string SignatureStatus(const std::wstring& path) {
  WINTRUST_FILE_INFO file{};
  file.cbStruct = sizeof(file);
  file.pcwszFilePath = path.c_str();
  GUID action = WINTRUST_ACTION_GENERIC_VERIFY_V2;
  WINTRUST_DATA trust{};
  trust.cbStruct = sizeof(trust);
  trust.dwUIChoice = WTD_UI_NONE;
  trust.fdwRevocationChecks = WTD_REVOKE_NONE;
  trust.dwUnionChoice = WTD_CHOICE_FILE;
  trust.pFile = &file;
  trust.dwStateAction = WTD_STATEACTION_VERIFY;
  trust.dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL;
  const LONG status = ::WinVerifyTrust(
      static_cast<HWND>(INVALID_HANDLE_VALUE), &action, &trust);
  const DWORD last_error = ::GetLastError();
  trust.dwStateAction = WTD_STATEACTION_CLOSE;
  ::WinVerifyTrust(static_cast<HWND>(INVALID_HANDLE_VALUE), &action, &trust);

  if (status == ERROR_SUCCESS) {
    return "valid";
  }
  if (status == TRUST_E_NOSIGNATURE &&
      (last_error == static_cast<DWORD>(TRUST_E_NOSIGNATURE) ||
       last_error == static_cast<DWORD>(TRUST_E_SUBJECT_FORM_UNKNOWN) ||
       last_error == static_cast<DWORD>(TRUST_E_PROVIDER_UNKNOWN))) {
    return "unsigned";
  }
  return "invalid";
}

EncodableValue InspectInstaller(const std::wstring& path) {
  if (!IsPlainFilePath(path)) {
    return EncodableValue();
  }
  DWORD handle = 0;
  const DWORD size = ::GetFileVersionInfoSizeW(path.c_str(), &handle);
  if (size == 0) {
    return EncodableValue();
  }
  std::vector<BYTE> data(size);
  if (!::GetFileVersionInfoW(path.c_str(), 0, size, data.data())) {
    return EncodableValue();
  }
  EncodableValue version;
  VS_FIXEDFILEINFO* fixed = nullptr;
  UINT fixed_size = 0;
  if (::VerQueryValueW(data.data(), L"\\", reinterpret_cast<void**>(&fixed),
                       &fixed_size) &&
      fixed_size >= sizeof(VS_FIXEDFILEINFO) &&
      fixed->dwSignature == 0xFEEF04BD) {
    version = EncodableValue(
        std::to_string(HIWORD(fixed->dwProductVersionMS)) + "." +
        std::to_string(LOWORD(fixed->dwProductVersionMS)) + "." +
        std::to_string(HIWORD(fixed->dwProductVersionLS)));
  }
  return EncodableValue(EncodableMap{
      {EncodableValue("productName"),
       EncodableValue(Utf8FromUtf16(
           QueryVersionString(data, L"ProductName").c_str()))},
      {EncodableValue("companyName"),
       EncodableValue(Utf8FromUtf16(
           QueryVersionString(data, L"CompanyName").c_str()))},
      {EncodableValue("version"), version},
      {EncodableValue("signature"), EncodableValue(SignatureStatus(path))},
  });
}

// The folder holding this Reelish.exe, without a trailing backslash.
std::wstring AppDirectory() {
  std::wstring path(32768, L'\0');
  const DWORD length = ::GetModuleFileNameW(
      nullptr, path.data(), static_cast<DWORD>(path.size()));
  if (length == 0 || length >= path.size()) {
    return std::wstring();
  }
  path.resize(length);
  const size_t separator = path.find_last_of(L'\\');
  return separator == std::wstring::npos ? std::wstring()
                                         : path.substr(0, separator);
}

// Starts |installer| (an Inno Setup installer built from reelish.iss) for
// this app's folder. /SILENT shows only its progress window; it waits for
// Reelish to exit (kReelishAppMutex) before replacing files, and /RELAUNCH=1
// makes it open Reelish again afterwards, or reopen this version when the
// installation fails or is cancelled.
bool LaunchInstaller(const std::wstring& installer, const std::wstring& log) {
  if (!IsPlainFilePath(installer) || log.find(L'"') != std::wstring::npos ||
      _wcsicmp(installer.substr(installer.size() - 4).c_str(), L".exe") != 0) {
    return false;
  }
  const std::wstring app_directory = AppDirectory();
  if (app_directory.empty() ||
      app_directory.find(L'"') != std::wstring::npos) {
    return false;
  }
  std::wstring parameters = L"/SP- /SILENT /NORESTART /CLOSEAPPLICATIONS "
                            L"/RELAUNCH=1 /DIR=\"" +
                            app_directory + L"\"";
  if (!log.empty()) {
    parameters += L" /LOG=\"" + log + L"\"";
  }
  std::wstring command_line = L"\"" + installer + L"\" " + parameters;

  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  PROCESS_INFORMATION process{};
  // Outside any job Reelish runs in, so closing Reelish can never end the
  // installer half way. Not every job allows that; then start it normally.
  for (const DWORD flags : {static_cast<DWORD>(CREATE_BREAKAWAY_FROM_JOB |
                                               CREATE_NEW_PROCESS_GROUP),
                            static_cast<DWORD>(CREATE_NEW_PROCESS_GROUP)}) {
    std::vector<wchar_t> buffer(command_line.begin(), command_line.end());
    buffer.push_back(L'\0');
    if (::CreateProcessW(installer.c_str(), buffer.data(), nullptr, nullptr,
                         FALSE, flags, nullptr, nullptr, &startup,
                         &process)) {
      ::CloseHandle(process.hThread);
      ::CloseHandle(process.hProcess);
      return true;
    }
    const DWORD error = ::GetLastError();
    if (error == ERROR_ELEVATION_REQUIRED) {
      // The installer asks for administrator rights (it should not: it
      // installs per user). Let Windows show the UAC prompt.
      SHELLEXECUTEINFOW execute{};
      execute.cbSize = sizeof(execute);
      execute.fMask = SEE_MASK_NOASYNC;
      execute.lpVerb = L"open";
      execute.lpFile = installer.c_str();
      execute.lpParameters = parameters.c_str();
      execute.nShow = SW_SHOWNORMAL;
      return ::ShellExecuteExW(&execute) != FALSE;
    }
    if (error != ERROR_ACCESS_DENIED) {
      return false;
    }
  }
  return false;
}

}  // namespace

AppUpdateChannel::AppUpdateChannel(flutter::BinaryMessenger* messenger,
                                   HWND window)
    : window_(window) {
  channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
      messenger, "reelish/app_update",
      &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        const std::string& method = call.method_name();
        if (method == "inspectInstaller") {
          result->Success(InspectInstaller(PathArgument(call, "path")));
        } else if (method == "freeDiskSpace") {
          const std::wstring path = PathArgument(call, "path");
          ULARGE_INTEGER available{};
          if (path.empty() || !::GetDiskFreeSpaceExW(path.c_str(), &available,
                                                     nullptr, nullptr)) {
            result->Success();
            return;
          }
          result->Success(
              EncodableValue(static_cast<int64_t>(available.QuadPart)));
        } else if (method == "launchInstaller") {
          if (!LaunchInstaller(PathArgument(call, "path"),
                               PathArgument(call, "logPath"))) {
            result->Success(EncodableValue(false));
            return;
          }
          result->Success(EncodableValue(true));
          // A normal close: the same shutdown as the user closing the
          // window, after this reply reaches Dart.
          ::PostMessage(window_, WM_CLOSE, 0, 0);
        } else {
          result->NotImplemented();
        }
      });
}
