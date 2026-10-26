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

## Install

```sh
brew install gergogyulai/tap/berth
```

This also puts the `berth` CLI on your `PATH`. Or grab the zip from [Releases](https://github.com/gergogyulai/berth/releases). The app isn't notarized, so a manual install needs **System Settings → Privacy & Security → Open Anyway** on first launch.

## Layout

| Path | What |
| --- | --- |
| `Packages/BerthKit` | Engine: models, NetFS mounter, DiskArbitration watcher, probes, network monitor, rules, coordinator, IPC, nsmb.conf. Run `swift test` here. |
| `Berth/` | SwiftUI app: windows, menu bar, settings, notifications, hot keys, AppleScript, App Intents. |
| `BerthCLI/` | `berth` command-line tool, embedded at `Berth.app/Contents/Helpers/berth`. |
| `Berth/AppIcon.icon` | Icon Composer (Liquid Glass) app icon. |

## Build

Open `Berth.xcodeproj` and run the **Berth** scheme, or:

```sh
xcodebuild -project Berth.xcodeproj -scheme Berth -configuration Release build
```

The project signs ad-hoc ("Sign to Run Locally"). To distribute, set your team and use a Developer ID. With an ad-hoc signature, macOS may ask again for Keychain access after each rebuild.

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
