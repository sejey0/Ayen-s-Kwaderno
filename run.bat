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
echo Select Run Mode:
echo [1] Standard Debug Run (Incremental Build)
echo [2] Fast Attach (No Build / Rekta Debugger)
echo [3] Release Mode (Full Build)
echo [4] Clean ^& Fresh Rebuild (Compiles ML Kit ^& Plugins)
echo ==========================================

choice /c 1234 /m "Piliin ang opsyong gusto mo"
if errorlevel 4 goto RUN_CLEAN
if errorlevel 3 goto RUN_RELEASE
if errorlevel 2 goto RUN_ATTACH
if errorlevel 1 goto RUN_DEBUG
goto END

:RUN_CLEAN
echo.
echo Cleaning build cache and fetching packages...
call flutter clean
call flutter pub get
echo Starting app with fresh native plugin compilation...
call flutter run
goto END

:RUN_RELEASE
echo.
echo Starting app in RELEASE mode...
flutter run --release
goto END

:RUN_ATTACH
echo.
echo Attaching to running app (Walang build, instant connect)...
flutter attach
goto END

:RUN_DEBUG
echo.
echo Starting app in DEBUG mode...
flutter run
goto END

:END
pause