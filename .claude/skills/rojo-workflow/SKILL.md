---
name: rojo-workflow
description: Build, live-sync and sync back this Roblox project with Rojo on Windows. Use when the user wants to open the game in Studio, rebuild the place, start/restart rojo serve, add a remote or folder to default.project.json, get Studio-made changes (props, materials) back into git, or when Rojo / the Studio plugin isn't connecting.
---

# Rojo workflow (Windows)

Rojo 7.7.0 is installed at `%USERPROFILE%\.rojo-bin\rojo.exe` and that folder is on the user PATH. If `rojo` isn't found in the current shell (PATH added after the shell started), call it by full path: `& "$env:USERPROFILE\.rojo-bin\rojo.exe"`.

The Studio plugin is `%LOCALAPPDATA%\Roblox\Plugins\RojoManagedPlugin.rbxm` (reinstall with `rojo plugin install`, then restart Studio).

## Commands (run from the repo root)

| Goal | Command |
|---|---|
| Build a place file | `rojo build -o sekiro-like.rbxl` |
| Open it in Studio | `Start-Process (Resolve-Path sekiro-like.rbxl)` |
| Live sync files → Studio | `rojo serve` (run in background; then Studio **Plugins → Rojo → Connect**, default port 34872) |
| Sourcemap for luau-lsp | `rojo sourcemap -o sourcemap.json` (gitignored) |
| Pull Studio changes into files | `rojo syncback` (save the place in Studio first) |

## Rules

- **Never `rojo build` over a `.rbxl` that's open in Studio** — it overwrites anything made in Studio. Build to another name (`-o build-test.rbxl`) if unsure.
- `*.rbxl` is gitignored. Hand-placed content (`Workspace.Props`, MaterialService) lives only in the creator's place file until someone runs `rojo syncback` and commits it. A fresh build from git has no props; that's expected.
- Sync is one-way while serving: **files → Studio**. Script edits made inside Studio are overwritten on the next file change. Always edit `src/`.
- After editing `default.project.json` (new remote, folder or `$properties`), restart `rojo serve`; it doesn't hot-reload project structure. Reconnect in Studio.
- Only one `rojo serve` per port. If the port is in use, stop the old one (`Get-NetTCPConnection -LocalPort 34872`) or pass `--port`.
- Lighting values in `default.project.json` mirror `src/shared/LightingProfile.luau`; change both together.

## Troubleshooting

- Plugin missing in Studio → `rojo plugin install`, fully restart Studio.
- Connect fails → is `rojo serve` running? Same port in the plugin? Windows firewall prompt on first run?
- Instances duplicated after connect → the place already had the scripts; accept Rojo's diff or rebuild into a fresh file.
- Version mismatch warning → plugin and CLI must both be 7.7.x; reinstall the plugin.
