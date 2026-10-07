# Truck PC installer

One script that sets up the truck PC for the Comfortably Yum register, Kitchen Display and menu board
(steps 3.1 to 3.11 of the User Manual).

## Use it

1. Copy this folder to the new PC. Put the KFIDisplay program next to it, as a folder named `KFIDisplay`
   (containing `KFIDisplay.exe` and its DLLs), a `KFIDisplay*.zip` of that folder, or the `KFIDisplay*.msi` from
   the installer. (Or pass `-KfiDisplaySource <path>`.)
2. Double-click **Install-TruckPC.bat**. Windows asks for administrator permission.
3. Wait. It takes 10 to 30 minutes on a new PC, mostly SQL Server. At the end it prints a summary with the PC's
   addresses and the **sync key** for the register tablet (also saved in `C:\KFDisplay\tablet-setup.txt`, which you
   should delete once the tablets are set up).
4. Put your own `disclaimer.jpg` in `C:\images`, and give the PC a fixed address in the router.

To see what it would do without changing anything, run `Install-TruckPC.bat -DryRun`.

## What it does

| Step | Detail |
| --- | --- |
| Prerequisites | Git, Node.js LTS (winget). Checks .NET Framework 4.8. Skips what is already installed. |
| SQL Server | Installs SQL Server 2022 Express silently (instance `SQLEXPRESS`) if missing. Turns on SQL logins, enables TCP/IP on port 1433, restarts SQL Server if it changed anything, and checks your Windows account is an administrator. |
| Programs | Clones `kfdisplay-sync`, `KitchenDisplay` and `KFIDisplay` from GitHub into `C:\Source` (updates a clean existing copy). Creates `C:\images` and `C:\KFDisplay`, copies `slash.gif`, runs `npm install`. |
| Menu board | Installs KFIDisplay (copy, unzip or msi) to `C:\Program Files\KF\Menu Display`, adds a desktop shortcut and a start-when-anyone-signs-in shortcut. |
| Database | Uses KFIDisplay's own setup code to create the `KFDisplay` database, its 13 tables, and the `register_sync` and `kitchen_display` logins with random passwords. |
| `.env` files | Writes both from the projects' `.env.example` with a new sync key and the new passwords. **Never overwrites an existing `.env`.** The temporary password files are deleted. |
| Windows | Firewall rules for TCP 8787 and 8790 (Private and Domain networks), and start-at-boot tasks for both services with no time limit. |
| Start | Starts both services and checks they answer. |

It is safe to run again: every step checks first, nothing is dropped, and no existing login or `.env` is touched.

## Options

| Option | Meaning |
| --- | --- |
| `-DryRun` | Report only. No administrator rights needed. |
| `-KfiDisplaySource <path>` | Folder, `.zip` or `.msi` with the menu board program. |
| `-KfiDisplayExe <path>` | A `KFIDisplay.exe` already in place (used as is, nothing installed). |
| `-SqlInstallerPath <path>` | An offline SQL Server Express setup file, instead of downloading with winget. |
| `-SkipPrerequisites`, `-SkipSql`, `-SkipKfiDisplay`, `-SkipWindowsSetup` | Leave out a step. |
| `-NoStart`, `-NoAutostart`, `-NoShortcuts` | Do not start the services / do not add the startup shortcut / add no shortcuts. |
| `-SourceRoot`, `-ImagesDir`, `-AppDataDir`, `-SqlInstance`, `-DatabaseName`, `-SyncLogin`, `-KitchenLogin`, `-GitHubOwner` | Change a name or folder. The programs themselves expect the defaults (`C:\Source`, `C:\images`, `KFDisplay`). |
| `-NoElevate`, `-NoPause` | Do not ask for administrator permission / do not wait for Enter at the end. |

Everything it does is logged to `C:\KFDisplay\install.log`.

## What it does not do

- The tablets. Install the two APKs and set up the apps by hand (User Manual sections 4 and 5). The summary gives
  you the address and sync key to type.
- Square, Wix, Venmo, printers and Bluetooth: these need your accounts and the tablet's own screens.
- Build the programs. It needs a finished KFIDisplay (`KFIDisplay.exe`), which depends on a private DLL
  (`LicenseVerification.dll`), so it is supplied, not built.
- `disclaimer.jpg`: your own picture.

## Tests

```
powershell -ExecutionPolicy Bypass -File tests\Test-TruckInstaller.ps1
powershell -ExecutionPolicy Bypass -File tests\Test-TruckInstaller.ps1 -Integration
```

The first runs the helper functions and a dry run. `-Integration` also runs the real steps into a scratch folder
against this PC's SQL Server with a throwaway database (`KFDisplayTest`) and logins, starts both services from the
generated `.env` files on spare ports, runs the installer a second time, and removes everything.

**Not covered by the tests** (they need a clean PC or administrator rights): the winget installs, the SQL Server
Express install and its registry settings, creating firewall rules and scheduled tasks, and installing the
KFIDisplay msi. Try the script on a spare PC or a virtual machine before relying on it for a real replacement.
