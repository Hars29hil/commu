@echo off
echo ==========================================================
echo   Off-Grid Message Mail - Mobile APK Installer (ADB)
echo ==========================================================
echo.
adb devices
echo.
echo Installing app-release.apk to connected Android devices...
adb install -r build\app\outputs\flutter-apk\app-release.apk
echo.
echo ==========================================================
echo   Installation completed! Open 'Message Mail' on phone.
echo ==========================================================
pause

