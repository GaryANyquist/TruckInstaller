# Truck installers

Two scripts for the Comfortably Yum system:

| Script | Sets up | Manual |
| --- | --- | --- |
| `Install-TruckPC.bat` | The truck PC: SQL Server, Node.js, the sync and Kitchen Display services, the database, the menu board, firewall and boot tasks. | Steps 3.1 to 3.11 |
| `Install-Tablets.bat` | The register and Kitchen Display apps on Android tablets plugged into the PC with a USB cable. | Steps 4.2 and 5.2 (and the permissions in 4.5 and 5.4) |

Do the truck PC first. The tablet installer is described at the end of this file.

# Truck PC installer

One script that sets up the truck PC for the Comfortably Yum register, Kitchen Display and menu board.

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

---

# Tablet installer

`Install-Tablets.bat` installs or updates the two Android apps on tablets plugged into the PC with a USB cable, using
`adb`. It never uninstalls an app, because that would erase its sales and settings, and an update keeps the app's data.

## Before you run it

On each tablet: Settings > About tablet > tap **Build number** 7 times, then Settings > System > **Developer options** >
turn on **USB debugging**. Plug in the cable, set the USB mode to **File transfer**, and tap **Allow** on the tablet's
"Allow USB debugging?" box (tick Always allow).

Put the APK files next to the script (or in an `apk` folder next to it). If you build the apps on this PC, it also finds
them in the build folders by itself. It picks the newest version of each: `AnnawareCashRegister-<version>-live.apk`
(older builds were named `ComfortablyYum-<version>-live.apk`; both are found) and `KitchenDisplay-<version>.apk`.

If `adb` is not on the PC, the script downloads Google's platform-tools (about 7 MB) into a `tools` folder next to it.

## Use it

Double-click **Install-Tablets.bat**. For each tablet it shows the model, serial and what is installed, and asks whether it
is the Register, the Kitchen Display, both, or to skip. It then installs, opens the app, and prints a summary.

Or give the answers in advance:

```
Install-Tablets.bat -Role Register -GrantPermissions -TurnOffDeveloperOptions
Install-Tablets.bat -RegisterSerial ABC123 -KitchenSerial DEF456 -GrantPermissions -Yes
Install-Tablets.bat -DryRun
```

## Options

| Option | Meaning |
| --- | --- |
| `-Role Register`, `Kitchen` or `Both` | What the one connected tablet is. |
| `-RegisterSerial`, `-KitchenSerial` | Which tablet is which, when two are plugged in (serials are shown when it runs). |
| `-RegisterApk`, `-KitchenApk` | A specific APK file. |
| `-GrantPermissions` | Pre-allow the permissions the apps need (Bluetooth, location, phone and microphone for the register; microphone for the kitchen app), so there are fewer prompts. |
| `-SetKitchenAsHome` | Make Annaware Kitchen Display the tablet's Home app (needs app 1.2.0+), so Android opens it by itself every time the tablet starts. The old Home app is recorded in the summary with the command that puts it back. |
| `-TurnOffDeveloperOptions` | After installing the register, switch Developer options and USB debugging off (needed for the live Square reader). Do this last: adb stops working on that tablet afterwards. |
| `-WixKeyFile`, `-SettingsBackup` | Copy a Wix key file or a register settings backup into the tablet's Download folder, for Settings > Wix menu > **Load key from file** and Settings > Backup > **Restore settings**. Delete them from the tablet afterwards. |
| `-Reinstall` | Install again even if the same version is already there. |
| `-PcAddress` | Shown in the "still to do" lines at the end. |
| `-NoLaunch`, `-NoDownload`, `-WaitSeconds`, `-Yes`, `-DryRun`, `-NoPause`, `-AdbPath` | Do not open the app / do not download adb / wait for a tablet to appear / do not ask questions / report only / do not wait at the end / use this adb. |

## What it cannot do

Apps keep their settings in private storage, so the PC address, sync key, Square, Wix, Venmo, printers and Bluetooth
pairing still have to be entered on the tablet (User Manual sections 4 and 5). The summary says what is left.

## Tests

```
powershell -ExecutionPolicy Bypass -File tests\Test-TabletInstaller.ps1
powershell -ExecutionPolicy Bypass -File tests\Test-TabletInstaller.ps1 -Integration
```

The first checks the parsing and file-finding code and, if a tablet is plugged in, a dry run and a "leave current apps
alone" run. `-Integration` also reinstalls the Kitchen Display app over itself (same version, data kept), tries the
permission grant and a file copy, and restores the tablet.

Not covered: installing an app that is not on the tablet yet, a different version, `-TurnOffDeveloperOptions` (it ends the
adb connection), and a second tablet.
