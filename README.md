<img src="assets/icon.svg" width="64" height="64" alt="">

# Berth

A macOS 26+ utility that mounts your SMB shares and keeps them mounted at home, over Tailscale, and after sleep. It runs from the menu bar and the Dock.

## Highlights

- **Shares**: host + fallback addresses, share, user/domain, guest or anonymous. Each share has its own name, icon, mount point and group.
- **Keychain**: one password item per share, plus a change-credentials flow (unmount → update → remount).
- **Connection handling**: auto-mount at login or whenever the network allows. Reconnects after Wi-Fi ↔ Ethernet switches, sleep/wake and VPN changes. Stale mounts are found by off-main-thread probes with timeouts and get force-unmounted and remounted cleanly. Finder ejects are told apart from dropped connections (DiskArbitration). Retries use exponential backoff.
- **Network awareness**: "Tailscale down" is its own state, MagicDNS/100.x names are detected, and each share can follow network rules (home Wi-Fi only, or home with Tailscale elsewhere). Also includes Wake-on-LAN and pausing on metered networks.
- **Performance**: a per-server `~/Library/Preferences/nsmb.conf` editor with *Fast LAN*, *Tailscale/WAN* and *Compatibility* presets, plus a per-share speed test.
- **Finder**: custom volume icons, optional pinning to the sidebar, Open in Finder/Terminal, Copy Path, and import from mounted volumes, Finder recent servers and Bonjour.
- **Automation**: global hot keys, Shortcuts actions, AppleScript, `berth://` URLs and the `berth` CLI.
- **Sync**: iCloud Drive config sync and JSON export/import. Passwords are never synced or exported.

## Berth Cloud (this branch)

Every share can now pick its **backend** (Share editor → Backend → *Connect Using*):

| | macOS SMB (Volume) | Berth Cloud |
| --- | --- | --- |
| Where it appears | `/Volumes/…`, a mounted volume | Finder → Locations, next to iCloud Drive (`~/Library/CloudStorage/Berth-…`) |
| SMB client | macOS's `smbfs` (NetFS) | **BerthSMB**, Berth's own SMB 2/3.1.1 client |
| Files | Always remote | Downloaded on demand, cached, evictable; edits upload in the background |
| Dead server | Finder can beachball until the mount is forced off | Finder keeps showing the cached tree; nothing blocks |
| Live updates | smbfs notifications | `CHANGE_NOTIFY` watch, pushed to the extension |

It is a drop-in replacement: the same shares, addresses and fallbacks, network rules, Tailscale handling, Wake-on-LAN, Keychain password, retries with backoff, health probes, notifications, CLI, AppleScript, Shortcuts and `berth://` URLs. Only the mount step changes: instead of NetFS, Berth signs in with BerthSMB (so a wrong password or a missing share fails exactly like a mount would) and then adds or reconnects a File Provider domain. *Unmount* disconnects the location (it stays in the sidebar, greyed out, with its downloaded files); removing the share or switching it back to the macOS backend removes the location.

How it fits together:

- `Packages/BerthSMB` — the SMB client (see its [README](Packages/BerthSMB/README.md)): pipelined multi-credit I/O, compounded metadata round trips, NTLMv2, SMB 3.1.1 signing (AES-GMAC/CMAC) and encryption (AES-GCM), reconnects. `swift run berth-smb bench smb://user@host/share` measures it.
- `BerthCloud/` — the File Provider (replicated) extension, embedded at `Berth.app/Contents/PlugIns/BerthCloud.appex`. It keeps a SQLite index that maps stable item identifiers to server paths and file ids (so renames, moves and other clients' safe-saves keep their identity) and a change log whose sequence numbers are the sync anchors.
- `Packages/BerthKit/Sources/BerthKit/Cloud` — the app side (`CloudVolumes`: domains, an SMB session per share for ECHO probes and `CHANGE_NOTIFY`, XPC to the extension) and the shared engine/index.

The extension stores its configuration and password itself: Berth pushes them over the extension's XPC service (which only accepts connections from Berth's own signature), so no keychain sharing entitlement is needed.

**Signing.** File Provider extensions have to be sandboxed and in an App Group. That works best with an Apple Development or Developer ID team: set `DEVELOPMENT_TEAM` (Signing & Capabilities) for both the **Berth** and **BerthCloud** targets. Ad-hoc builds compile and run, but macOS may refuse to load the extension or ask for access to the group container; the macOS backend is unaffected either way. The first cloud location also has to be allowed in **System Settings → General → Login Items & Extensions → File Providers**.

**Not (yet) supported by the cloud backend:** Kerberos (NTLMv2 only), DFS referrals, SMB 3.0/3.0.2 encryption (AES-CCM; 3.1.1 AES-GCM works), symlinks, extended attributes and Finder tags on the server, and the nsmb.conf presets (cloud shares map the preset onto BerthSMB tuning instead).

## Install

```sh
brew install gergogyulai/tap/berth
```

This also puts the `berth` CLI on your `PATH`. Or grab the zip from [Releases](https://github.com/gergogyulai/berth/releases). The app isn't notarized, so a manual install needs **System Settings → Privacy & Security → Open Anyway** on first launch.

## Layout

| Path | What |
| --- | --- |
| `Packages/BerthKit` | Engine: models, NetFS mounter, DiskArbitration watcher, probes, network monitor, rules, coordinator, IPC, nsmb.conf, and the cloud backend (`Cloud/`). Run `swift test` here. |
| `Packages/BerthSMB` | Berth's own SMB 2/3.1.1 client, plus the `berth-smb` tool. Runs on macOS and Linux; `swift test` here (set `BERTH_SMB_TEST_URL` for the live-server tests). |
| `BerthCloud/` | File Provider extension that serves cloud-backed shares. |
| `Berth/` | SwiftUI app: windows, menu bar, settings, notifications, hot keys, AppleScript, App Intents. |
| `BerthCLI/` | `berth` command-line tool, embedded at `Berth.app/Contents/Helpers/berth`. |
| `Berth/AppIcon.icon` | Icon Composer (Liquid Glass) app icon. |

## Build

Open `Berth.xcodeproj` and run the **Berth** scheme, or:

```sh
xcodebuild -project Berth.xcodeproj -scheme Berth -configuration Release build
```

Local builds sign ad-hoc ("Sign to Run Locally"), so macOS may ask again for Keychain access after each rebuild. Release builds are signed with a self-signed certificate from `scripts/make-signing-cert.sh`, which keeps the app's identity stable across updates. It isn't a Developer ID, so Gatekeeper still treats the app as unnotarized.

## Command line

Install from **Settings → Automation**, then:

```sh
berth list
berth mount nas-media
berth unmount --group Backups --force
cd "$(berth path nas-media)"
```

## Scripting

```applescript
tell application "Berth"
    mount "NAS Media"            -- waits; returns true when mounted
    get state of every share
    unmount all group "Backups"
end tell
```

URLs: `berth://mount/<share>`, `berth://unmount/<share>`, `berth://mount-all?group=Media`, `berth://open/<share>`.

## License

MIT
