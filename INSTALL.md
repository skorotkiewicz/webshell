# Build and run

The build creates a ready-to-use Alpine WebShell VM. No manual installer, guest login or host root access is needed.

## Host requirements

Use a Linux host with QEMU's x86_64 emulator, `qemu-img`, `curl`, Python 3, `ssh-keygen`, `sha512sum` and `mkisofs`. Allow 2 GiB of RAM for the guest. KVM is used when available; otherwise QEMU falls back to slower software emulation.

On Debian or Ubuntu, install the host tools:

```sh
sudo apt install qemu-system-x86 qemu-utils genisoimage curl python3 openssh-client
```

Other distributions provide `mkisofs` through `cdrtools` or `genisoimage`.

## Build once

From the repository:

```sh
./build.sh 4G
```

`4G` is the total virtual disk size, not RAM or each account's quota. Sizes are whole GiB, at least `2G`; omitting the argument uses `4G`. The sparse disk only consumes host space as data is written.

The script downloads the official Alpine 3.23.4 BIOS cloud image and verifies its pinned SHA-512 checksum. The verified base is cached as `.alpine-3.23.4.qcow2`. It then creates a standalone disk, grows the root filesystem, installs WebShell and social, enables user disk quotas and unified cgroups, and configures key-only SSH administration.

A temporary cloud-init ISO provisions the VM. The guest reboots, checks its authentication helpers and HTTP service, disables cloud-init, and shuts down. Only a successful build publishes `webshell.qcow2`, `webshell-key` and `webshell-key.pub` in the repository root. The disk needs neither the base image nor the seed ISO to run.

Existing disks or admin keys are never overwritten. To build another VM, move all three existing files aside first. Failed builds keep their files and `console.log` under the printed `.build.*` directory. Completed build files are retained too; the workspace disk and published disk are hard links to the same file, not independent backups.

## Run

```sh
./run.sh
```

Open http://localhost:8080. Type `new`, choose a password and save the account UUID. Accounts and home files persist across disconnects and reboots.

The VM stays in the foreground. SSH and HTTP forwarding bind only to host localhost.

For administration or a clean shutdown, use another terminal:

```sh
ssh -i ./webshell-key -p 10022 root@localhost
# Inside the guest:
poweroff
```

There is no known root password; only the generated private key provides normal administrator access. Protect it, and back it up alongside the powered-off VM disk. Losing it requires offline recovery. Force-killing QEMU can lose recent writes.

## Check and upgrade

Run `test-limits.sh` inside a WebShell user session to inspect its cgroup and disk quota settings. Per-account defaults are in `webshell-auth.sh`; update the test's expected values when changing them.

The image currently uses external ext4 user quotas. Alpine's kernel warns that these are deprecated, but the tested kernel enforces them. Migrate to internal quotas before upgrading to a kernel that removes external quota support.

Updating repository scripts does not update an already-built disk. Back up the powered-off disk, then copy the changed scripts into the guest through SSH and reboot. Do not rebuild over permanent account data. Keep the guest packages patched with `apk upgrade` as administrator.

This is for a trusted small group, not untrusted public signup. For remote access, use an SSH tunnel or a TLS reverse proxy with access control. See [README.md](README.md) for the security boundary.
