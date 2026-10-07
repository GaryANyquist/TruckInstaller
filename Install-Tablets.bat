@echo off
rem Installs the register and Kitchen Display apps on Android tablets plugged into this PC with a USB cable.
rem Any options are passed on, for example:  Install-Tablets.bat -Role Register -GrantPermissions
rem                                          Install-Tablets.bat -DryRun
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-Tablets.ps1" %*
