; VALUNIVO — Windows installer (Inno Setup 6).
; Built by .github/workflows/windows.yml:
;   iscc /DAppVersion=1.0.N /DSourceDir=<Release folder> /DOutputDir=<out> app\windows_installer\valunivo.iss
; Installs the real Flutter Windows app (VALUNIVO.exe + its DLLs + data\) — not a web shortcut.
; Per-user install (no admin prompt), so in-app updates can run the next installer silently.
; Contents: VALUNIVO.exe, VALUNIVO-Updater.exe (update helper), flutter_windows.dll, plugin DLLs, VC++ runtime, data\.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef SourceDir
  #define SourceDir "..\build\windows\x64\runner\Release"
#endif
#ifndef OutputDir
  #define OutputDir "..\build\installer"
#endif

#define AppName "VALUNIVO"
#define AppExe "VALUNIVO.exe"
#define AppPublisher "Value Group"
#define AppUrl "https://jaurea.com/valunivo/"
; must match WindowsInitializationSettings.appUserModelId (notification_service.dart)
#define AppUserModelId "ValueGroup.VALUNIVO"

[Setup]
; never change AppId: it is how an update finds the installed copy
AppId={{8C3B5E2A-6F41-4D7B-9A0E-5D2C7B1F9E36}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppPublisher}
AppPublisherURL={#AppUrl}
AppSupportURL={#AppUrl}
AppUpdatesURL={#AppUrl}
VersionInfoVersion={#AppVersion}
VersionInfoCompany={#AppPublisher}
VersionInfoDescription={#AppName} Setup
VersionInfoProductName={#AppName}
VersionInfoProductVersion={#AppVersion}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=commandline dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
; the app holds this mutex while open (windows/runner/main.cpp): setup asks to close it / closes it on update
AppMutex=VALUNIVO_Desktop_SingleInstance
CloseApplications=yes
RestartApplications=no
OutputDir={#OutputDir}
OutputBaseFilename=VALUNIVO-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ShowLanguageDialog=auto

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
#if FileExists(AddBackslash(CompilerPath) + "Languages\Arabic.isl")
Name: "arabic"; MessagesFile: "compiler:Languages\Arabic.isl"
#endif

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
; files are overwritten in place (no pre-delete), so a failed / cancelled update is rolled back by Setup
; and the previous version keeps working. Settings and the sign-in live in AppData, not here.
; the whole Release folder: VALUNIVO.exe, flutter_windows.dll, every plugin DLL, the VC++ runtime DLLs, data\
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"; AppUserModelID: "{#AppUserModelId}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; AppUserModelID: "{#AppUserModelId}"; Tasks: desktopicon

[Run]
; normal install: offer to open the app at the end
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
; in-app updates are run by VALUNIVO-Updater.exe, which reopens the app itself and checks it starts
