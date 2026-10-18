# slim-m for Windows

There are two ways in, and both create the same per-user install that updates itself, laid out as decision 0041 describes.

`slim-m-setup-<version>.exe` is the first choice.
It is an Inno Setup installer (`slim-m.iss`) that needs no administrator rights, installs into `%LOCALAPPDATA%\slim-m`, adds a Start menu shortcut and an optional desktop one, and registers an uninstaller in Apps & Features.
Running a newer setup over an existing install upgrades it in place, writing the `previous` and `current` pointers the way the updater does.
Setup and the uninstaller both notice a running slim-m (through its `Local\top.npcserver.slimm.instance` mutex) and ask you to close it first.
Closing the window only sends slim-m to the tray, so quit it from the tray icon's menu (Quit slim-m), then click OK.
Start on login registers the stable `slim-m.exe` launcher, so a login start follows updates; the app rewrites an older registration that named a versioned folder.
Uninstalling removes the app folders, the launcher, the pointers, the `running.pid` marker, a "Start on login" entry that points into the install, and the install folder itself once it is empty.
The app keeps its data under `%APPDATA%`, outside that folder, so uninstalling leaves it alone.

The zip is the second choice.
Extract it anywhere and double-click `install.cmd`.
That copies the app to `%LOCALAPPDATA%\slim-m\app-<version>\`, puts the `slim-m.exe` launcher beside it, and adds a Start menu shortcut.
Nothing outside your profile is touched and there is no elevation prompt.

Windows cannot replace a running exe, so each version lives in its own folder.
`slim-m.exe` reads the `current` file, which holds a version number, and starts that folder.
An update unpacks the next version into a new folder, rewrites `current` through a temp file and a replacing rename, and restarts through the launcher.

The previous version is kept until the new one has stayed up for 20 seconds, then older folders are removed.
If the new version fails to start three times in a row, the launcher moves `current` back to `previous` and the app says so in a banner.

A copy run straight from the extracted folder, a machine-wide copy under `Program Files` and a packaged MSIX are never modified by the updater.
For the extracted folder, Settings > About offers "Install for automatic updates", which copies that folder into the layout, adds the Start menu shortcut and restarts through the launcher.
Each version folder also carries its own `slim-m.exe`.
Once a version has run cleanly (`pending` is cleared), the launcher at the root compares itself to that copy and replaces itself if they differ.
It copies the new one to `slim-m.new.exe`, runs it once with `--launcher-selftest`, renames itself to `slim-m.exe.old` (a running exe can be renamed but not overwritten) and renames the copy into place, undoing the first rename if the second fails.
Any failure leaves the old launcher working, and a launcher that does not understand the self-test is never run or swapped in.
If an interruption ever leaves no `slim-m.exe` at the root, running `app-<version>\slim-m.exe` starts the app and puts the launcher back.
A launcher from before this change cannot swap itself, so one more run of `install.cmd` or the setup is needed to pick it up.
The build is unsigned, so SmartScreen will warn on first run.

Build the setup with `iscc /DAppVersion=<version> /DSourceDir=<release folder> slim-m.iss`; `desktop-clients.yml` does this after the zip.

`launcher/` holds the launcher's source (Go).
Run `go generate ./...` in `launcher/` first: it embeds the app icon as a resource (`rsrc_windows_amd64.syso`, gitignored) with a pinned go-winres.
Then build it with `GOOS=windows go build -ldflags "-H=windowsgui -s -w" -o slim-m.exe ./launcher`.
