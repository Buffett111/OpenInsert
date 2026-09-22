; Inno Setup 6.3 or newer. Inputs are supplied by package-windows.ps1.
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef AppArchitecture
  #error AppArchitecture is required
#endif
#ifndef AppVersionNumber
  #error AppVersionNumber is required
#endif
#ifndef PublishDir
  #error PublishDir is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif

[Setup]
AppId={{C295075F-B64D-4DDC-95C6-71BBE31F2C73}
AppName=OpenInsert
AppVersion={#AppVersion}
VersionInfoVersion={#AppVersionNumber}
AppPublisher=OpenInsert contributors
AppPublisherURL=https://github.com/Buffett111/OpenInsert
AppSupportURL=https://github.com/Buffett111/OpenInsert/issues
AppUpdatesURL=https://github.com/Buffett111/OpenInsert/releases
DefaultDirName={localappdata}\Programs\OpenInsert
DefaultGroupName=OpenInsert
DisableProgramGroupPage=yes
AllowNoIcons=yes
PrivilegesRequired=lowest
#if AppArchitecture == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
MinVersion=10.0.17763
OutputDir={#OutputDir}
OutputBaseFilename=OpenInsert-{#AppVersion}-windows-{#AppArchitecture}-setup
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
LicenseFile={#PublishDir}\LICENSE.txt
UninstallDisplayIcon={app}\OpenInsert.exe
CloseApplications=yes
RestartApplications=no
SetupLogging=no

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Additional shortcuts:"; Flags: unchecked

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\OpenInsert"; Filename: "{app}\OpenInsert.exe"
Name: "{userdesktop}\OpenInsert"; Filename: "{app}\OpenInsert.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\OpenInsert.exe"; Description: "Launch OpenInsert"; Flags: nowait postinstall skipifsilent

; App preferences and the DPAPI-encrypted key are intentionally retained on
; uninstall. Do not recursively delete a user's data from the installer.
