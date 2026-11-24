#define MyAppName "DastRas NG"
#define MyAppExe "DastRas-NG.exe"
#ifndef MyAppVersion
  #define MyAppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "DastRas-NG"
#endif

[Setup]
AppId={{6F2D8B1C-4A7E-4D39-9C15-3B8E2F7A9D10}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher=DastRas
DefaultDirName={autopf}\DastRas NG
DefaultGroupName=DastRas NG
DisableProgramGroupPage=yes
; installs for the current user, so no administrator rights are needed and in-app updates can write to the folder
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
OutputDir=Output
OutputBaseFilename=DastRas-NG-Setup
SetupIconFile=app_icon.ico
UninstallDisplayIcon={app}\{#MyAppExe}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
CloseApplications=force
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"
Name: "startup"; Description: "Start DastRas NG when Windows starts"; GroupDescription: "Options:"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\DastRas NG"; Filename: "{app}\{#MyAppExe}"
Name: "{autodesktop}\DastRas NG"; Filename: "{app}\{#MyAppExe}"; Tasks: desktopicon

[Registry]
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "DastRasNG"; ValueData: """{app}\{#MyAppExe}"" --minimized"; Flags: uninsdeletevalue; Tasks: startup

[Run]
Filename: "{app}\{#MyAppExe}"; Description: "Launch DastRas NG"; Flags: nowait postinstall skipifsilent

[UninstallRun]
; give the user's proxy settings back before the files are removed
Filename: "{app}\{#MyAppExe}"; Parameters: "--cleanup"; Flags: runhidden waituntilterminated; RunOnceId: "Cleanup"
