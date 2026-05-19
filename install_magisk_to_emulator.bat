@echo off
setlocal enabledelayedexpansion
title Magisk Delta System Mode Installer
chcp 65001 > nul

echo ========================================
echo  Magisk Delta (System Mode) Installer
echo  by HuskyDG - Kitsune Version
echo ========================================
echo.

set PATH=C:\Program Files\Netease\MuMu\nx_device\12.0\shell;%PATH%
adb devices

REM Environment check & device connection
echo [CHECK] Checking ADB connection status...
adb devices | findstr "device" > nul
if errorlevel 1 (
    echo ! No ADB device detected
    echo ! Please ensure emulator is running and debugging is enabled
    pause
    exit /b 1
)

echo [CHECK] Getting device information...
for /f "tokens=*" %%i in ('adb shell getprop ro.product.cpu.abi') do set ABI=%%i
for /f "tokens=*" %%i in ('adb shell getprop ro.build.version.sdk') do set API=%%i
echo - Device platform: %ABI%
echo - API Level: %API%

REM Check if device is already rooted or has Magisk installed
echo [CHECK] Checking device ROOT status...
adb shell su -c "echo ROOT_OK" 2>nul | findstr "ROOT_OK" > nul
if not errorlevel 1 (
    echo ! Device already has ROOT privileges
    echo ! May have other ROOT solutions installed
    choice /c YN /m "Continue installation (Y/N)? "
    if errorlevel 2 exit /b 1
)

REM File preparation & permission acquisition
echo.
echo [PREPARE] Checking installation files...
if not exist "Kitsune-Mask-debug-27.0" (
    echo ! Cannot find Kitsune-Mask-debug-27.0 directory
    echo ! Please ensure APK is extracted or directory exists
    pause
    exit /b 1
)

echo [PREPARE] Creating working directory...
adb shell mkdir -p /data/local/tmp/magisk_install

REM File transfer to Android device - directly use extracted directory
echo.
echo [TRANSFER] Pushing installation files to device...
if exist "Kitsune-Mask-debug-27.0\assets" (
    echo [TRANSFER] Pushing assets directory...
    adb push "Kitsune-Mask-debug-27.0\assets" /data/local/tmp/magisk_install/
) else (
    echo ! Cannot find assets directory
    pause
    exit /b 1
)

if exist "Kitsune-Mask-debug-27.0\lib\%ABI%" (
    echo [TRANSFER] Pushing lib/%ABI% directory...
    adb push "Kitsune-Mask-debug-27.0\lib\%ABI%" /data/local/tmp/magisk_install/lib/
) else (
    echo ! Cannot find lib/%ABI% directory
    echo ! Supported architectures: arm64-v8a, x86_64, x86, armeabi-v7a
    echo ! Current directory structure:
    if exist "Kitsune-Mask-debug-27.0\lib" (
        dir "Kitsune-Mask-debug-27.0\lib" /b
    )
    pause
    exit /b 1
)

if exist "Kitsune-Mask-debug-27.0\res\raw\manager.sh" (
    echo [TRANSFER] Pushing manager.sh...
    adb shell mkdir -p /data/local/tmp/magisk_install/res/raw/
    adb push "Kitsune-Mask-debug-27.0\res\raw\manager.sh" /data/local/tmp/magisk_install/res/raw/
) else (
    echo ! Cannot find manager.sh file, continuing installation...
)

echo [TRANSFER] Setting file permissions...
adb shell chmod -R 755 /data/local/tmp/magisk_install/

REM Call install_system.sh
echo.
echo [INSTALL] Creating system installation script...
adb push install_system.sh /data/local/tmp/
adb shell chmod 755 /data/local/tmp/install_system.sh

echo [INSTALL] Starting system mode installation...

REM Execute system installation script
adb shell "cd /data/local/tmp && export ABI=%ABI% && export API=%API% && su -c '/data/local/tmp/install_system.sh /data/local/tmp/magisk_install'"

if errorlevel 1 (
    echo.
    echo ! Installation failed
    echo ! Please check device compatibility and error messages
    pause
    exit /b 1
)

REM APK Installation
echo.
echo [APK] Checking for Magisk APK...
if exist "Kitsune-Mask-debug-27.0.apk" (
    echo [APK] Installing Magisk APK...
    set APK_INSTALLED=false
    
    REM Try standard adb install first
    adb install -r "Kitsune-Mask-debug-27.0.apk"
    if not errorlevel 1 (
        echo [APK] APK installed successfully
        set APK_INSTALLED=true
    ) else (
        echo [APK] Standard installation failed, trying alternative method...
        echo [APK] Pushing APK to device for manual installation...
        adb push "Kitsune-Mask-debug-27.0.apk" /data/local/tmp/magisk.apk
        adb shell "su -c 'pm install -r -g /data/local/tmp/magisk.apk'"
        if not errorlevel 1 (
            echo [APK] APK installed successfully via pm install
            adb shell "su -c 'rm -f /data/local/tmp/magisk.apk'" 2>nul
            set APK_INSTALLED=true
        ) else (
            echo ! APK installation failed via both methods
            echo ! You can manually install the APK later
            echo ! APK location on device: /data/local/tmp/magisk.apk
        )
    )
    
    REM Set up permissions if APK was installed successfully
    if "!APK_INSTALLED!"=="true" (
        echo [APK] Setting up Magisk app permissions...
        adb shell "su -c 'pm grant io.github.huskydg.magisk android.permission.REQUEST_INSTALL_PACKAGES'" 2>nul
        adb shell "su -c 'appops set io.github.huskydg.magisk REQUEST_INSTALL_PACKAGES allow'" 2>nul
        adb shell "su -c 'pm grant io.github.huskydg.magisk android.permission.WRITE_EXTERNAL_STORAGE'" 2>nul
        adb shell "su -c 'pm grant io.github.huskydg.magisk android.permission.READ_EXTERNAL_STORAGE'" 2>nul
        adb shell "su -c 'pm grant io.github.huskydg.magisk android.permission.READ_PHONE_STATE'" 2>nul
        echo [APK] Magisk app permissions configured
    )

) else (
    echo [APK] Kitsune-Mask-debug-27.0.apk not found, skipping APK installation
    echo [APK] You can manually install the Magisk app later if needed
)

echo.
echo [COMPLETE] Cleaning up installation files...
adb shell "su -c 'rm -rf /data/local/tmp/magisk_install'" 2>nul
adb shell "su -c 'rm -f /data/local/tmp/install_system.sh'" 2>nul
adb shell "su -c 'rm -rf /dev/tmp/magisk_mirror'" 2>nul

echo.
echo ========================================
echo  Installation Complete!
echo ========================================
echo.
echo - All done!
echo.
echo Installation program finished.
pause
