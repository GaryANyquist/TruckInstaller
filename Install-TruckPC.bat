@echo off
rem Sets up the truck PC. Double-click this file, or run it from a Command Prompt.
rem Any options are passed on, for example:  Install-TruckPC.bat -DryRun
rem                                           Install-TruckPC.bat -KfiDisplaySource C:\Setup\KFIDisplay.msi
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-TruckPC.ps1" %*
