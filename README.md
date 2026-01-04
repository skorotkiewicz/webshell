# WebShell

> A secure, sandboxed web terminal running inside QEMU.

---

## Overview

WebShell provides browser-accessible shell sessions through [ttyd](https://github.com/tsl0922/ttyd), with each user isolated in their own environment. Built on Alpine Linux, it enforces strict resource limits through cgroups v2.

## Features

- **User Isolation** — Each session runs as a separate Unix user
- **Resource Limits** — Memory (100MB), CPU (50%), PIDs (100), Disk (5MB)
- **Shared Files** — Collaborative workspace at `/shared-files`
- **Web Interface** — Access via `http://localhost:8080`

## Setup

See [`INSTALL.md`](INSTALL.md) for full setup:

1. Create a QEMU disk image
2. Install Alpine Linux
3. Configure quotas, cgroups, and ttyd
4. Deploy `webshell-auth.sh`
5. Deploy `tools/social.py` (optional)

## Running

```sh
cd qemu-os-virt
./run.sh
```

Open **http://localhost:8080** — type `new` to create an account.

## Architecture

```
┌─────────────────────────────────────────────────┐
│                    Browser                      │
└────────────────────────┬────────────────────────┘
                         │ :8080
┌────────────────────────▼────────────────────────┐
│                     ttyd                        │
└────────────────────────┬────────────────────────┘
                         │
┌────────────────────────▼────────────────────────┐
│              webshell-auth.sh                   │
│  ┌──────────────────────────────────────────┐   │
│  │ User Authentication → cgroups v2 Sandbox │   │
│  └──────────────────────────────────────────┘   │
└─────────────────────────────────────────────────┘
                    QEMU VM
```

## Configuration

| Resource | Default  |
|----------|----------|
| Memory   | 100 MB   |
| CPU      | 50%      |
| PIDs     | 100      |
| Disk     | 5 MB     |

Edit `webshell-auth.sh` to adjust limits.

## Requirements

- QEMU with KVM support
- Alpine Linux virtual image (`webshell.qcow2`)

## License

MIT
