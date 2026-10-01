# Testing-CODE — Windows in a GitHub Codespace (dockur/windows)

1. Edit `.env` (version, RAM, storage folder, download options — everything is commented).
2. `bash setup.sh`
3. Open port **8006** (PORTS tab) and wait; Windows downloads + installs by itself.

| Command | What it does |
|---|---|
| `bash setup.sh` | start / apply `.env` changes |
| `bash setup.sh status` | container, RAM, disk, recent log + hints |
| `bash setup.sh logs` | live log (download progress) |
| `bash setup.sh dns` | test DNS (use when download says *Failed to resolve hostname*) |
| `bash setup.sh stop` | stop Windows |
| `bash setup.sh reset` | delete Windows disk + downloads, start clean |

Windows 10 instead of 11: set `WIN_VERSION="10"` in `.env`, then `bash setup.sh reset`.
`.env` is git-ignored (it holds the Windows password); `.env.example` is the template.

## Troubleshooting

- **Forwarded port opens nothing** -> run `bash setup.sh status`. Usually the container is stopped
  (Codespace restarted). `bash setup.sh` starts it again.
- **Download: "Failed to resolve hostname"** -> `bash setup.sh dns`.
- **RAM**: keep `WIN_RAM="auto"` (about 8G on a 16GB Codespace). Too much RAM kills the whole Codespace.
- `/tmp` can be wiped when a Codespace stops; if `status` says "No Windows disk", Windows is installed again.
- Optional: `devcontainer.example.json` (always forward 8006 + auto-start Windows when the Codespace starts).
