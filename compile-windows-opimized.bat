@echo off
setlocal
rem Release + Astro Bot PGO + LTO, tuned for this PC. Tools live in _Build\tools.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\build-windows-optimized.ps1" %*
exit /b %ERRORLEVEL%
