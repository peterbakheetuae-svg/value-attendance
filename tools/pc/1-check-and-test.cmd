@echo off
rem Value Attendance - step 1: toolchain check, platform setup, pub get, analyze, test.
rem Logs go to ..\..\build-logs\ ; nothing outside D:\JPH\jph_real_estate_hr is modified.
setlocal
set ROOT=D:\JPH\jph_real_estate_hr
set LOG=%ROOT%\build-logs
set FLUTTER_ROOT=D:\dev\flutter-3.38
set JAVA_HOME=D:\dev\jdk-17
set ANDROID_HOME=D:\dev\android-sdk
set ANDROID_SDK_ROOT=D:\dev\android-sdk
set PATH=%FLUTTER_ROOT%\bin;%JAVA_HOME%\bin;%PATH%
rem flutter test breaks when an http proxy is set (localhost WebSocket gets proxied)
set http_proxy=
set https_proxy=
set HTTP_PROXY=
set HTTPS_PROXY=
set NO_PROXY=localhost,127.0.0.1,::1
if not exist "%LOG%" mkdir "%LOG%"
del /q "%LOG%\step1-*.txt" 2>nul
echo started %date% %time% > "%LOG%\step1-status.txt"
cd /d "%ROOT%\app"

call flutter --version > "%LOG%\step1-01-version.txt" 2>&1
echo version=%ERRORLEVEL% >> "%LOG%\step1-status.txt"
call flutter doctor -v > "%LOG%\step1-02-doctor.txt" 2>&1
echo doctor=%ERRORLEVEL% >> "%LOG%\step1-status.txt"
if not exist android (
  call flutter create --platforms=android,web --org com.jph.valueattendance --project-name jph_real_estate_hr . > "%LOG%\step1-03-create.txt" 2>&1
  echo create=%ERRORLEVEL% >> "%LOG%\step1-status.txt"
) else (
  echo create=skipped >> "%LOG%\step1-status.txt"
)
call dart run tool/patch_android.dart > "%LOG%\step1-04-patch.txt" 2>&1
echo patch=%ERRORLEVEL% >> "%LOG%\step1-status.txt"
call flutter pub get > "%LOG%\step1-05-pubget.txt" 2>&1
echo pubget=%ERRORLEVEL% >> "%LOG%\step1-status.txt"
call flutter analyze > "%LOG%\step1-06-analyze.txt" 2>&1
echo analyze=%ERRORLEVEL% >> "%LOG%\step1-status.txt"
call flutter test > "%LOG%\step1-07-test.txt" 2>&1
echo test=%ERRORLEVEL% >> "%LOG%\step1-status.txt"
echo DONE %date% %time% >> "%LOG%\step1-status.txt"
endlocal
