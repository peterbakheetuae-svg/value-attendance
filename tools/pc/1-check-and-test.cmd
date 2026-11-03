@echo off
rem Value Attendance - step 1 (v2): Flutter 3.38 toolchain, platform setup, pub get, analyze, test, web build.
rem Logs: ..\..\build-logs\ . Only files inside D:\JPH\jph_real_estate_hr are touched.
setlocal
set ROOT=D:\JPH\jph_real_estate_hr
set LOG=%ROOT%\build-logs
set FLUTTER_BIN=D:\dev\flutter-3.38\flutter\bin
set FLUTTER_ROOT=
set JAVA_HOME=D:\dev\jdk-17
set ANDROID_HOME=D:\dev\android-sdk
set ANDROID_SDK_ROOT=D:\dev\android-sdk
set PATH=%FLUTTER_BIN%;%JAVA_HOME%\bin;%PATH%
set http_proxy=
set https_proxy=
set HTTP_PROXY=
set HTTPS_PROXY=
set NO_PROXY=localhost,127.0.0.1,::1
if not exist "%LOG%" mkdir "%LOG%"
del /q "%LOG%\step1-*.txt" 2>nul
echo started %date% %time% > "%LOG%\step1-status.txt"
cd /d "%ROOT%\app"

call "%FLUTTER_BIN%\flutter.bat" --version > "%LOG%\step1-01-version.txt" 2>&1
echo version=%ERRORLEVEL% >> "%LOG%\step1-status.txt"
call "%FLUTTER_BIN%\flutter.bat" doctor -v > "%LOG%\step1-02-doctor.txt" 2>&1
echo doctor=%ERRORLEVEL% >> "%LOG%\step1-status.txt"

rem Remove platform files generated earlier by the obsolete Flutter 2.10.5 (only generated files)
if exist android\app\build.gradle if not exist android\app\build.gradle.kts rmdir /s /q android
if exist .metadata findstr /c:"5464c5bac7" .metadata >nul && (rmdir /s /q web & rmdir /s /q .idea & del /q .metadata *.iml README.md .gitignore 2>nul)

if not exist android (
  call "%FLUTTER_BIN%\flutter.bat" create --platforms=android,web --org com.jph.valueattendance --project-name jph_real_estate_hr . > "%LOG%\step1-03-create.txt" 2>&1
  echo create=%ERRORLEVEL% >> "%LOG%\step1-status.txt"
) else (
  echo create=skipped >> "%LOG%\step1-status.txt"
)
call "%FLUTTER_BIN%\dart.bat" run tool/patch_android.dart > "%LOG%\step1-04-patch.txt" 2>&1
echo patch=%ERRORLEVEL% >> "%LOG%\step1-status.txt"
call "%FLUTTER_BIN%\flutter.bat" pub get > "%LOG%\step1-05-pubget.txt" 2>&1
echo pubget=%ERRORLEVEL% >> "%LOG%\step1-status.txt"
call "%FLUTTER_BIN%\flutter.bat" analyze > "%LOG%\step1-06-analyze.txt" 2>&1
echo analyze=%ERRORLEVEL% >> "%LOG%\step1-status.txt"
call "%FLUTTER_BIN%\flutter.bat" test > "%LOG%\step1-07-test.txt" 2>&1
echo test=%ERRORLEVEL% >> "%LOG%\step1-status.txt"
call "%FLUTTER_BIN%\flutter.bat" build web --release --dart-define=API_BASE_URL=http://localhost:8095 > "%LOG%\step1-08-build-web.txt" 2>&1
echo buildweb=%ERRORLEVEL% >> "%LOG%\step1-status.txt"
echo DONE %date% %time% >> "%LOG%\step1-status.txt"
endlocal
