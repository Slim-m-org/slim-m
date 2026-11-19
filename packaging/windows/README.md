# slim-m for Windows

There are two ways in, and both create the same per-user install that updates itself, laid out as decision 0041 describes.

`slim-m-setup-<version>.exe` is the first choice.
It is an Inno Setup installer (`slim-m.iss`) that needs no administrator rights, installs into `%LOCALAPPDATA%\slim-m`, adds a Start menu shortcut and an optional desktop one, and registers an uninstaller in Apps & Features.
Running a newer setup over an existing install upgrades it in place, writing the `previous` and `current` pointers the way the updater does.
Setup and the uninstaller both notice a running slim-m (through its `Local\top.npcserver.slimm.instance` mutex) and ask you to close it first.
Closing the window only sends slim-m to the tray, so quit it from the tray icon (Quit slim-m; on Windows it may sit under the ^ overflow arrow), then click OK.
Start on login registers the stable `slim-m.exe` launcher, so a login start follows updates; the app rewrites an older registration that named a versioned folder.
It also registers the `slimm://` scheme for your user, so an invite link, Spotify's redirect and the Discord link's "Open slim-m" button reach this install, and a running copy is handed the link.
The app registers the scheme as well each time it starts, pointing it at the launcher when it runs from the per-user layout and at its own `slimm_app.exe` otherwise, so a zip install, `install.cmd` and a copy moved in from Settings > About get it too.
Without it a browser drops the redirect with no prompt, and Spotify's page simply stays on Agree.
The running copy takes the link even when the launcher starts a newer version folder than the one it came from, because the runner matches it by file name.
Uninstalling removes the app folders, the launcher, the pointers, the `running.pid` marker, a "Start on login" entry that points into the install, and the install folder itself once it is empty.
The app keeps its data under `%APPDATA%`, outside that folder, so uninstalling leaves it alone.

The zip is the second choice.
Extract it anywhere and double-click `install.cmd`.
That copies the app to `%LOCALAPPDATA%\slim-m\app-<version>\`, puts the `slim-m.exe` launcher beside it, and adds a Start menu shortcut.
Nothing outside your profile is touched and there is no elevation prompt.

Windows cannot replace a running exe, so each version lives in its own folder.
`slim-m.exe` reads the `current` file, which holds a version number, and starts that version from the `app` folder beside it.
`app` holds hard links to the files of the version `current` names, so every version runs from the same `app\slimm_app.exe` path and Windows Firewall sees one app across updates (see below).
An update unpacks the next version into a new folder, rewrites `current` through a temp file and a replacing rename, and restarts through the launcher, which then relinks `app`.

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

## The firewall prompt

Windows Firewall asks "Do you want to allow public and private networks to access this app?" the first time an exe listens for inbound connections, and records the answer as an inbound rule pair (TCP and UDP) keyed on that exe's full path.
libwebrtc is the only part of slim-m that listens: a passive TCP ICE candidate opens a listening socket on every interface address.
The mic preview's in-process loopback gathers no TCP candidates (`loopbackPeerConfiguration`), and a Windows call gathers none when the server offers TURN over TLS or TCP (`callPeerConfiguration`), so there is no prompt at all on such a deployment.
A deployment with no TCP relay keeps them, because LiveKit's TCP port is then the only way through a network that blocks UDP, so a call there can ask.
libwebrtc only reaches its TCP step when UDP has not connected first: in the Windows VM a call to a LAN server over UDP opened no listener, and the same call with LiveKit's UDP ports unreachable opened twelve and raised the prompt.
Cancel does not break that call: it blocks inbound only, and the TCP connection the call uses is outbound.
`client/packages/rtc/test/peer_connection_sites_gate_test.dart` fails when a peer connection is created anywhere else.
Both settings need the `tcpCandidatePolicy` key, which the WebRTC fork reads on Windows and Linux since `fix/desktop-tcp-candidate-policy`.

Because the rule is keyed on the path, every version runs from the same `app\slimm_app.exe`, so that question comes once per install, not once per update.
Before that, each version ran from its own `app-<version>` folder, so each update asked again and left one more rule pair behind for a folder that no longer exists.
Removing those needs an administrator, so slim-m leaves them alone; they are harmless, and an elevated PowerShell clears them with `Get-NetFirewallApplicationFilter | ? Program -like '*\slim-m\app-*' | Get-NetFirewallRule | Remove-NetFirewallRule`.

The launcher keeps `app` in step with `current`.
When every file of the version folder is already the same file under `app`, it starts it there.
Otherwise it builds `app.next` from hard links, renames `app` to `app.old`, renames `app.next` to `app` and deletes `app.old`.
It only does that when no process runs an exe from `app`, which it checks by the image path of every process it can see.
Neither deleting `app\slimm_app.exe` nor renaming `app` would prove it: Windows allows deleting one hard link of a running exe, and renaming a folder whose running exe holds no other files open.
A restart into an update waits up to 15 seconds for the old copy to exit; a launch while an older version still runs from `app`, and any failure, start the version folder directly instead, as before.
A junction would not do: the firewall records the path a junction resolves to.

To check a build by hand, from an elevated PowerShell:

1. `auditpol /set /subcategory:"{0CCE9226-69AE-11D9-BED3-505054503030}" /success:enable /failure:enable` turns on the Filtering Platform Connection audit.
2. Copy the release folder to a path that has never run, start it there, open Settings > Voice and screen share, then join and leave a call on a server that offers TURN over TLS.
3. `Get-WinEvent -FilterHashtable @{LogName='Security'; Id=5154,5031} | ? Message -match 'slimm_app'` must list nothing: 5154 is a socket permitted to listen, 5031 is the prompt.
   On a server without a TCP relay the same call lists them, and after an update to the per-user install a second call must list them for `app\slimm_app.exe` again but raise no new prompt or rule.
4. Set the subcategory back with `/success:disable /failure:disable`.

The audit log records a listener however briefly it lives, which polling `Get-NetTCPConnection -State Listen` cannot promise.
