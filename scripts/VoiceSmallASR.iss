#define MyAppName "VoiceSmallASR"
#ifndef AppVersion
  #define AppVersion "1.0.2"
#endif
#define MyAppVersion AppVersion
#define MyAppPublisher "VoiceSmallASR"
#define MyAppExeName "vsasr_app.exe"

#ifndef AppBuildDir
  #define AppBuildDir "..\app\build\windows\x64\runner\Release"
#endif

[Setup]
AppId={{A0A0C8D7-7F8E-4D7C-8CF1-6E84B2F8E0A1}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
DefaultDirName={localappdata}\Programs\{#MyAppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputBaseFilename=VoiceSmallASR-unsigned-setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern

[Files]
Source: "{#AppBuildDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent
