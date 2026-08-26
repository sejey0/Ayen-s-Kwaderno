@echo off
title Ayens Kwaderno Launcher

echo ==========================================
echo   AYEN'S KWADERNO - LAUNCHER
echo ==========================================
echo.

echo [1/3] Checking connected ADB devices...
set DEVICE_FOUND=
for /f "tokens=1" %%i in ('adb devices ^| findstr /R "\<device\>"') do (
    set DEVICE_FOUND=1
)

if defined DEVICE_FOUND (
    echo [OK] Device detected!
    goto SELECT_MODE
) else (
    echo [!] No active device found.
    echo.
    set /p CONNECT_WIRELESS="Do you want to connect via Wireless Debugging? (y/n): "
    if /i "%CONNECT_WIRELESS%"=="y" (
        echo.
        set /p ADB_ADDRESS="Enter Wireless Debugging IP and Port (e.g., 192.168.1.5:5555): "
        echo Connecting to %ADB_ADDRESS%...
        adb connect %ADB_ADDRESS%
        
        set DEVICE_FOUND=
        for /f "tokens=1" %%i in ('adb devices ^| findstr /R "\<device\>"') do (
            set DEVICE_FOUND=1
        )
        if defined DEVICE_FOUND (
            echo [OK] Successfully connected via wireless!
            goto SELECT_MODE
        ) else (
            echo [X] Connection failed. Please check IP and port.
            pause
            exit /b
        )
    ) else (
        echo [X] Aborted. Please connect your device first.
        pause
        exit /b
    )
)

:SELECT_MODE
echo.
echo ==========================================
echo Select Build Mode:
echo [1] Debug Mode
echo [2] Release Mode
echo ==========================================

choice /c 12 /m "Press 1 for Debug or 2 for Release"
if errorlevel 2 (
    echo.
    echo Starting app in RELEASE mode...
    flutter run --release
) else if errorlevel 1 (
    echo.
    echo Starting app in DEBUG mode...
    flutter run
)

pause