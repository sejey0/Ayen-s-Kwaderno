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