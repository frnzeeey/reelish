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
;   /SP- /SILENT /NORESTART /CLOSEAPPLICATIONS /RELAUNCH=1 /DIR="<app folder>" /LOG="<file>" /REELISHPID=<id>
;
; from the installer's own folder, and then closes Reelish. Setup waits for
; that Reelish process to exit, and for no Reelish to hold ReelishAppMutex,
; before replacing any file; opens the updated Reelish when done; and reopens
; the old one if the update fails or is cancelled. Versions before 1.15.1
; pass no /REELISHPID and start Setup in their own current folder, which can
; be the app folder; PrepareToInstall copes with both. See docs/windows.md.

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
const
  SYNCHRONIZE = $00100000;
  PROCESS_QUERY_LIMITED_INFORMATION = $1000;
  WAIT_TIMEOUT = $102;

function OpenProcess(DesiredAccess: DWORD; InheritHandle: BOOL;
  ProcessId: DWORD): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function WaitForSingleObject(Handle: THandle; Milliseconds: DWORD): DWORD;
  external 'WaitForSingleObject@kernel32.dll stdcall';
function CloseHandle(Handle: THandle): BOOL;
  external 'CloseHandle@kernel32.dll stdcall';
function QueryFullProcessImageName(Process: THandle; Flags: DWORD;
  ExeName: String; var Size: DWORD): BOOL;
  external 'QueryFullProcessImageNameW@kernel32.dll stdcall';

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

{ Reelish 1.15.1 and later pass their process ID (/REELISHPID=) when they
  start an update. Waiting on that process ends only once it has exited, not
  merely released its mutex, which it does a moment before it is gone. Older
  versions pass none; the mutex and the retries in PrepareToInstall cover
  them. }
procedure WaitForReelishThatStartedSetup;
var
  ProcessId, Size: DWORD;
  Process: THandle;
  Path: String;
begin
  ProcessId := StrToIntDef(ExpandConstant('{param:reelishpid|0}'), 0);
  Log('Started by Reelish process: ' + IntToStr(ProcessId) + ' (0: not given).');
  if ProcessId = 0 then
    Exit;
  Process := OpenProcess(SYNCHRONIZE or PROCESS_QUERY_LIMITED_INFORMATION,
    False, ProcessId);
  if Process = 0 then
  begin
    Log('Reelish (process ' + IntToStr(ProcessId) + ') had already exited.');
    Exit;
  end;
  try
    if WaitForSingleObject(Process, 0) = 0 then
    begin
      Log('Reelish (process ' + IntToStr(ProcessId) + ') has exited.');
      Exit;
    end;
    { A process ID can be reused: wait only for Reelish.exe itself. }
    Size := 1024;
    Path := StringOfChar(#0, Size);
    if not QueryFullProcessImageName(Process, 0, Path, Size) then
    begin
      Log('Could not identify process ' + IntToStr(ProcessId) + ' (error ' +
        IntToStr(DLLGetLastError) + '); not waiting for it.');
      Exit;
    end;
    Path := Copy(Path, 1, Size);
    if CompareText(ExtractFileName(Path), 'Reelish.exe') <> 0 then
    begin
      Log('Process ' + IntToStr(ProcessId) + ' is not Reelish: ' + Path);
      Exit;
    end;
    Log('Waiting for Reelish (process ' + IntToStr(ProcessId) + ') to exit.');
    if WaitForSingleObject(Process, 60000) = WAIT_TIMEOUT then
      Log('Reelish has not exited after 60 s.')
    else
      Log('Reelish has exited.');
  finally
    CloseHandle(Process);
  end;
end;

function InitializeSetup: Boolean;
var
  Waited: Integer;
begin
  if ShouldRelaunch then
    WaitForReelishThatStartedSetup;
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
  Instead the installed version is moved aside first, the new version is
  installed into a clean folder (no stale files of older versions), and the
  old one is deleted on success or moved back on failure.

  What moves is the folder's contents, not the folder: Windows refuses to
  move a folder that is any process's current directory, and Reelish
  started from its Start menu shortcut runs in it, so Setup started by that
  Reelish (1.15.0 and earlier) does too. Its files still move. }
var
  AppDir, BackupDir: String;
  BackedUp: Boolean;

{ Moves every file and folder in FromDir into ToDir. With Replace, an entry
  already in ToDir (a file of the new version) is deleted first. Returns
  whether everything moved; what could not move stays where it was. }
function MoveContents(const FromDir, ToDir: String; Replace: Boolean): Boolean;
var
  Find: TFindRec;
  Names: TStringList;
  I: Integer;
  Target: String;
begin
  Result := True;
  Names := TStringList.Create;
  try
    if FindFirst(AddBackslash(FromDir) + '*', Find) then
    try
      repeat
        if (Find.Name <> '.') and (Find.Name <> '..') then
          Names.Add(Find.Name);
      until not FindNext(Find);
    finally
      FindClose(Find);
    end;
    for I := 0 to Names.Count - 1 do
    begin
      Target := AddBackslash(ToDir) + Names[I];
      if Replace and (FileExists(Target) or DirExists(Target)) then
        DelTree(Target, DirExists(Target), True, True);
      if not RenameFile(AddBackslash(FromDir) + Names[I], Target) then
      begin
        Log('In use, not moved yet: ' + AddBackslash(FromDir) + Names[I]);
        Result := False;
      end;
    end;
  finally
    Names.Free;
  end;
end;

{ MoveContents, retried every 250 ms for up to Seconds: a closing Reelish
  holds its files for a moment after it exits, and security software can
  hold one briefly while it scans it. }
function MoveContentsRetrying(const FromDir, ToDir: String; Replace: Boolean;
  Seconds: Integer): Boolean;
var
  Attempt: Integer;
begin
  for Attempt := 1 to Seconds * 4 do
  begin
    Result := MoveContents(FromDir, ToDir, Replace);
    if Result then
    begin
      if Attempt > 1 then
        Log('Moved after ' + IntToStr(Attempt) + ' attempts.');
      Exit;
    end;
    Sleep(250);
  end;
end;

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
    ForceDirectories(AppDir);
    if MoveContentsRetrying(BackupDir, AppDir, True, 5) then
    begin
      RemoveDir(BackupDir);
      Log('Restored the previous version left in ' + BackupDir);
    end;
  end;
  if not FileExists(AddBackslash(AppDir) + 'Reelish.exe') then
    Exit; { A new installation: nothing to keep. }
  if DirExists(BackupDir) and not DelTree(BackupDir, True, True, True) then
  begin
    Result := 'An earlier backup of Reelish could not be removed: ' +
      BackupDir + #13#10#13#10 + 'Delete that folder, then run the update again.';
    Exit;
  end;
  if not CreateDir(BackupDir) then
  begin
    Result := 'Setup could not create ' + BackupDir + ' to keep the current ' +
      'version safe during the update, so nothing was changed.';
    Exit;
  end;
  { From here on, whatever has moved is moved back if the update fails. }
  BackedUp := True;
  if not MoveContentsRetrying(AppDir, BackupDir, False, 30) then
  begin
    Result := 'Reelish''s files in ' + AppDir + ' are still in use by another ' +
      'program, so the update was not installed and your current version ' +
      'was kept.' + #13#10#13#10 + 'Close Reelish and any program using ' +
      'that folder (such as a file manager or a virus scan), then run the ' +
      'update again.';
    Exit;
  end;
  Log('Previous version moved to ' + BackupDir);
end;

var
  { Set once Setup starts writing the new version's files. }
  Installing: Boolean;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssInstall then
    Installing := True;
  if CurStep = ssPostInstall then
    Installed := True;
end;

{ After a failed or cancelled update: the previous version, back in place.
  Retried for up to 30 s, since what failed the update is usually a file
  briefly held by another program (such as a virus scan). }
function RestorePrevious: Boolean;
begin
  Result := True;
  if not BackedUp then
    Exit;
  ForceDirectories(AppDir);
  { Once the new version was being written, what it installed goes first and
    each file of the previous version replaces anything left under its name.
    Before that, everything still in the app folder is the previous version
    (what could not be moved aside) and stays as it is. }
  if Installing then
    DelTree(AddBackslash(AppDir) + '*', False, True, True);
  Result := MoveContentsRetrying(BackupDir, AppDir, Installing, 30);
  if Result then
    RemoveDir(BackupDir);
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
