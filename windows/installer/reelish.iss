; Reelish for Windows: a per-user installer (no administrator rights).
;
; Built by .github/workflows/release-windows.yml from the verified
; `flutter build windows --release` output:
;
;   ISCC /DAppVersion=1.12.0 /DSourceDir=<Release folder> /DOutputDir=<dir> reelish.iss
;
; It installs into %LOCALAPPDATA%\Programs\Reelish. User data is not in the
; app folder (settings, library, history and plugins are in
; %APPDATA%\frnzeeey\Reelish, the window placement in HKCU\Software\frnzeeey\
; Reelish), so installing, updating and uninstalling never touch it.
;
; The in-app updater (windows/runner/app_update_channel.cpp) starts this
; installer with fixed arguments:
;
;   /SP- /SILENT /NORESTART /CLOSEAPPLICATIONS /RELAUNCH=1 /DIR="<app folder>" /LOG="<file>"
;
; and then closes Reelish. Setup waits for Reelish to exit (the
; ReelishAppMutex it holds while running) before replacing any file, opens the
; updated Reelish when done, and reopens the old one if the update fails or
; is cancelled. See docs/windows.md.

#ifndef AppVersion
  #error Define AppVersion as MAJOR.MINOR.PATCH, for example ISCC /DAppVersion=1.12.0
#endif
#ifndef SourceDir
  #error Define SourceDir as the build\windows\x64\runner\Release folder
#endif
#ifndef OutputDir
  #define OutputDir "Output"
#endif

; Never change: Windows identifies the installed app by it.
#define AppId "08D66CA7-880C-4A65-B1EE-E8E91DB569F6"
#define AppMutexName "ReelishAppMutex"

[Setup]
AppId={{{#AppId}}
AppName=Reelish
AppVersion={#AppVersion}
AppVerName=Reelish {#AppVersion}
AppPublisher=frnzeeey
AppPublisherURL=https://github.com/frnzeeey/reelish
AppSupportURL=https://github.com/frnzeeey/reelish/issues
AppUpdatesURL=https://github.com/frnzeeey/reelish/releases
; Read by the in-app updater, which only runs an installer that names
; Reelish by frnzeeey at exactly the version it offered.
VersionInfoVersion={#AppVersion}
VersionInfoProductVersion={#AppVersion}
VersionInfoProductTextVersion={#AppVersion}
VersionInfoProductName=Reelish
VersionInfoCompany=frnzeeey
VersionInfoDescription=Reelish Setup
VersionInfoCopyright=Copyright (C) 2026 frnzeeey
PrivilegesRequired=lowest
DefaultDirName={autopf}\Reelish
UsePreviousAppDir=yes
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir={#OutputDir}
OutputBaseFilename=Reelish-Setup-x64
SetupIconFile={#SourcePath}..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\Reelish.exe
UninstallDisplayName=Reelish
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
; One installation at a time.
SetupMutex=ReelishSetupMutex
CloseApplications=yes
RestartApplications=no
SetupLogging=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Reelish"; Filename: "{app}\Reelish.exe"
Name: "{autodesktop}\Reelish"; Filename: "{app}\Reelish.exe"; Tasks: desktopicon

[Run]
; Interactive installs: the "Launch Reelish" box on the last page.
Filename: "{app}\Reelish.exe"; Description: "{cm:LaunchProgram,Reelish}"; Flags: nowait postinstall skipifsilent
; In-app updates (/RELAUNCH=1): open the updated Reelish.
Filename: "{app}\Reelish.exe"; Flags: nowait; Check: ShouldRelaunch

[Code]
var
  Installed: Boolean;

function ShouldRelaunch: Boolean;
begin
  Result := ExpandConstant('{param:relaunch|0}') = '1';
end;

function ReelishRunning: Boolean;
begin
  Result := CheckForMutexes('{#AppMutexName}');
end;

function InitializeSetup: Boolean;
var
  Waited: Integer;
begin
  { An in-app update starts Setup, then closes Reelish: give it time to
    exit cleanly before asking. }
  Waited := 0;
  while ShouldRelaunch and ReelishRunning and (Waited < 60000) do
  begin
    Sleep(250);
    Waited := Waited + 250;
  end;
  { Files of a running Reelish are never replaced. }
  while ReelishRunning do
  begin
    if SuppressibleMsgBox('Reelish is still running. Close Reelish, then choose Retry to continue.',
         mbError, MB_RETRYCANCEL, IDCANCEL) = IDCANCEL then
    begin
      Log('Reelish is still running; Setup cancelled without changes.');
      Result := False;
      Exit;
    end;
  end;
  Result := True;
end;

{ Setup's own rollback removes the files it added but cannot restore the
  ones it replaced, so a failed update could leave a mix of two versions.
  Instead the installed app folder is moved aside first, the new version is
  installed into a clean folder (no stale files of older versions), and the
  old folder is deleted on success or moved back on failure. }
var
  AppDir, BackupDir: String;
  BackedUp: Boolean;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  AppDir := RemoveBackslashUnlessRoot(ExpandConstant('{app}'));
  BackupDir := AppDir + '.previous';
  { An earlier update that could not put the previous version back (a file
    stayed locked) left it in the backup folder: restore it first. }
  if not FileExists(AddBackslash(AppDir) + 'Reelish.exe') and
     FileExists(AddBackslash(BackupDir) + 'Reelish.exe') then
  begin
    if DirExists(AppDir) then
      DelTree(AppDir, True, True, True);
    if RenameFile(BackupDir, AppDir) then
      Log('Restored the previous version left in ' + BackupDir);
  end;
  if not FileExists(AddBackslash(AppDir) + 'Reelish.exe') then
    Exit; { A new installation: nothing to keep. }
  if DirExists(BackupDir) and not DelTree(BackupDir, True, True, True) then
  begin
    Result := 'An earlier backup of Reelish could not be removed: ' + BackupDir;
    Exit;
  end;
  if not RenameFile(AppDir, BackupDir) then
  begin
    Result := 'Reelish''s files are in use, so the update was not installed. ' +
      'Close any program using them and try again.';
    Exit;
  end;
  BackedUp := True;
  Log('Previous version moved to ' + BackupDir);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    Installed := True;
end;

{ After a failed or cancelled update: the previous version, back in place.
  Retried for up to 30 s, since what failed the update is usually a file
  briefly held by another program (such as a virus scan). }
function RestorePrevious: Boolean;
var
  Attempt: Integer;
begin
  Result := True;
  if not BackedUp then
    Exit;
  for Attempt := 1 to 30 do
  begin
    if DirExists(AppDir) then
      DelTree(AppDir, True, True, True);
    Result := RenameFile(BackupDir, AppDir);
    if Result then
      Break;
    Sleep(1000);
  end;
  if Result then
    Log('Update not installed; previous version restored.')
  else
    Log('Update not installed; the previous version is still in ' + BackupDir);
end;

procedure DeinitializeSetup;
var
  ResultCode: Integer;
  Previous: String;
begin
  if Installed then
  begin
    if BackedUp then
      DelTree(BackupDir, True, True, True);
    Exit;
  end;
  if RestorePrevious then
    Previous := ExpandConstant('{param:dir|}')
  else
    Previous := BackupDir;
  { A failed or cancelled update reopens the Reelish that started it. }
  if ShouldRelaunch and not ReelishRunning and (Previous <> '') and
     FileExists(AddBackslash(Previous) + 'Reelish.exe') then
  begin
    Log('Reopening ' + AddBackslash(Previous) + 'Reelish.exe');
    Exec(AddBackslash(Previous) + 'Reelish.exe', '', Previous, SW_SHOWNORMAL, ewNoWait, ResultCode);
  end;
end;

function InitializeUninstall: Boolean;
begin
  Result := True;
  while ReelishRunning do
  begin
    if SuppressibleMsgBox('Reelish is running. Close Reelish, then choose Retry to uninstall it.',
         mbError, MB_RETRYCANCEL, IDCANCEL) = IDCANCEL then
    begin
      Result := False;
      Exit;
    end;
  end;
end;
