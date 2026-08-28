@echo off
title Ayens Kwaderno Launcher

echo ==========================================
echo   AYEN'S KWADERNO - LAUNCHER
echo ==========================================
echo.

:: [0/4] Optimize Gradle Properties
echo [0/4] Injecting Gradle performance properties...
set "GRADLE_PROP=android\gradle.properties"

if not exist "%GRADLE_PROP%" goto SKIP_GRADLE

findstr /C:"org.gradle.daemon" "%GRADLE_PROP%" >nul || echo org.gradle.daemon=true>>"%GRADLE_PROP%"
findstr /C:"org.gradle.parallel" "%GRADLE_PROP%" >nul || echo org.gradle.parallel=true>>"%GRADLE_PROP%"
findstr /C:"org.gradle.configuration-cache" "%GRADLE_PROP%" >nul || echo org.gradle.configuration-cache=false>>"%GRADLE_PROP%"
findstr /C:"org.gradle.caching" "%GRADLE_PROP%" >nul || echo org.gradle.caching=true>>"%GRADLE_PROP%"
findstr /C:"org.gradle.jvmargs" "%GRADLE_PROP%" >nul || echo org.gradle.jvmargs=-Xmx2560m -XX:+UseParallelGC -XX:MaxMetaspaceSize=512m>>"%GRADLE_PROP%"
findstr /C:"android.enableJetifier" "%GRADLE_PROP%" >nul || echo android.enableJetifier=false>>"%GRADLE_PROP%"
findstr /C:"android.newDsl" "%GRADLE_PROP%" >nul || echo android.newDsl=true>>"%GRADLE_PROP%"
findstr /C:"android.builtInKotlin" "%GRADLE_PROP%" >nul || echo android.builtInKotlin=true>>"%GRADLE_PROP%"
echo [OK] Gradle optimized for 8GB RAM (heap capped at 2.5GB).
goto GRADLE_DONE

:SKIP_GRADLE
echo [!] android/gradle.properties not found. Skipping auto-injection.

:GRADLE_DONE
echo.

:: Windows Defender Visual Reminder Banner
echo ##################################################
echo #  WINDOWS DEFENDER EXCLUSION REMINDER            #
echo #  Add these paths to Virus and Threat Protection  #
echo #  Settings to speed up builds:                    #
echo #                                                  #
echo #  1. C:\Users\mjhay\flutter                       #
echo #  2. C:\Users\mjhay\.gradle                       #
echo #  3. (Exclude your current project folder)        #
echo ##################################################
echo.

echo [1/4] Checking connected ADB devices...
set DEVICE_FOUND=
for /f "tokens=1" %%i in ('adb devices ^| findstr /R "\<device\>"') do set "DEVICE_FOUND=1"

if defined DEVICE_FOUND goto SELECT_MODE

echo [!] No active device found.
echo.
set /p CONNECT_WIRELESS="Do you want to connect via Wireless Debugging? (y/n): "
if /i "%CONNECT_WIRELESS%" neq "y" goto ABORT_LAUNCH

echo.
set /p ADB_ADDRESS="Enter Wireless Debugging IP and Port (e.g., 192.168.1.5:5555): "
echo Connecting to %ADB_ADDRESS%...
adb connect %ADB_ADDRESS%

set DEVICE_FOUND=
for /f "tokens=1" %%i in ('adb devices ^| findstr /R "\<device\>"') do set "DEVICE_FOUND=1"
if defined DEVICE_FOUND goto SELECT_MODE

echo [X] Connection failed. Please check IP and port.
pause
exit /b

:ABORT_LAUNCH
echo [X] Aborted. Please connect your device first.
pause
exit /b

:SELECT_MODE
echo.
echo ==========================================
echo Select Run Mode:
echo Standard Debug Run (Implicit ABI-slicing)
echo Fast Attach (No Build / Rekta Debugger)
echo Release Mode (Optimized Deployment)
echo Clean and Fresh Rebuild (Full Refresh)
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
call flutter pub get --no-precompile
echo Starting app with fresh native plugin compilation...
call flutter run --no-dds --android-skip-build-dependency-validation
goto END

:RUN_RELEASE
echo.
echo Starting app in RELEASE mode...
call flutter run --release --no-dds --android-skip-build-dependency-validation
goto END

:RUN_ATTACH
echo.
echo [i] Reminder: Siguraduhing nakabukas ang app sa iyong device bago mag-attach!
echo Attaching to running app (Walang build, instant connect)...
call flutter attach
goto END

:RUN_DEBUG
echo.
echo [3/4] Starting DEBUG build...
call flutter run --no-dds --android-skip-build-dependency-validation
goto END

:END
echo.
echo [DONE] Launcher finished.
pause
