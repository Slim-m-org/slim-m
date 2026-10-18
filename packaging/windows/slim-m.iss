; SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
; Per-user setup that lays out exactly what install.ps1 does (decision 0041):
; %LOCALAPPDATA%\slim-m\app-<version>\, the slim-m.exe launcher at the root, and
; the `current` and `previous` pointer files. Compile with
;   iscc /DAppVersion=<version> /DSourceDir=<extracted release folder> /O<out dir> slim-m.iss

#ifndef AppVersion
  #error AppVersion is required: pass /DAppVersion=<version>
#endif
#ifndef SourceDir
  #error SourceDir is required: pass /DSourceDir=<release folder with slim-m.exe>
#endif

[Setup]
AppId={{6F1D2B5E-3C0A-4E7B-9A52-5D8E1C4B7A30}
AppName=slim-m
AppVersion={#AppVersion}
AppPublisher=slim-m
SetupIconFile=..\..\client\packages\app\windows\runner\resources\app_icon.ico
AppMutex=Local\top.npcserver.slimm.instance
DefaultDirName={localappdata}\slim-m
DisableDirPage=yes
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=slim-m-setup-{#AppVersion}
UninstallDisplayName=slim-m
UninstallDisplayIcon={app}\slim-m.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=yes
RestartApplications=no

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}\app-{#AppVersion}"; Excludes: "install.cmd,install.ps1,*.lib,*.exp"; Flags: recursesubdirs createallsubdirs ignoreversion
Source: "{#SourceDir}\slim-m.exe"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\slim-m"; Filename: "{app}\slim-m.exe"
Name: "{autodesktop}\slim-m"; Filename: "{app}\slim-m.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\slim-m.exe"; Description: "Start slim-m"; Flags: nowait postinstall skipifsilent

[Code]
const
  MOVEFILE_REPLACE_EXISTING = 1;

function MoveFileExW(Source, Target: String; Flags: Integer): Boolean;
  external 'MoveFileExW@kernel32.dll stdcall';

// Written through a temp file and a replacing rename, as the updater does.
procedure WritePointer(Name, Version: String);
var
  Temp: String;
begin
  Temp := ExpandConstant('{app}\.' + Name + '.new');
  SaveStringToFile(Temp, Version, False);
  if not MoveFileExW(Temp, ExpandConstant('{app}\' + Name), MOVEFILE_REPLACE_EXISTING) then
    RaiseException('could not write the ' + Name + ' pointer');
end;

procedure PointAtThisVersion;
var
  Before: AnsiString;
begin
  if LoadStringFromFile(ExpandConstant('{app}\current'), Before) then
  begin
    Before := Trim(Before);
    if (Before <> '') and (Before <> '{#AppVersion}') then
      WritePointer('previous', Before);
  end;
  DeleteFile(ExpandConstant('{app}\pending'));
  DeleteFile(ExpandConstant('{app}\pending.tries'));
  WritePointer('current', '{#AppVersion}');
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    PointAtThisVersion;
end;

procedure DeleteMatching(Pattern: String);
var
  Found: TFindRec;
  Dir: String;
begin
  Dir := ExpandConstant('{app}\');
  if FindFirst(Dir + Pattern, Found) then
  try
    repeat
      if Found.Attributes and FILE_ATTRIBUTE_DIRECTORY <> 0 then
        DelTree(Dir + Found.Name, True, True, True)
      else
        DeleteFile(Dir + Found.Name);
    until not FindNext(Found);
  finally
    FindClose(Found);
  end;
end;

// Start on login registers the launcher; a value pointing elsewhere is not ours to remove.
procedure RemoveLoginStart;
var
  Command: String;
begin
  if RegQueryStringValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'slim-m', Command) then
    if Pos(Lowercase(ExpandConstant('{app}\')), Lowercase(Command)) > 0 then
      RegDeleteValue(HKCU, 'Software\Microsoft\Windows\CurrentVersion\Run', 'slim-m');
end;

// The app's own data lives under %APPDATA%, outside this folder, and stays.
procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usPostUninstall then
  begin
    DeleteMatching('app-*');
    DeleteMatching('.unpack-*');
    DeleteMatching('.staging');
    DeleteMatching('slim-m*.exe*');
    DeleteMatching('current');
    DeleteMatching('previous');
    DeleteMatching('pending*');
    DeleteMatching('rolled-back');
    DeleteMatching('failed-version');
    DeleteMatching('.*.new');
    DeleteMatching('running.pid');
    RemoveLoginStart;
    RemoveDir(ExpandConstant('{app}'));
  end;
end;
