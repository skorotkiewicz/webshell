# WebShell

A small Alpine browser terminal inside QEMU. Each account gets a private Unix home and survives reconnects and VM restarts on `webshell.qcow2`.

## Build and run

Install the host tools in [INSTALL.md](INSTALL.md), then:

```sh
./build.sh 4G
./run.sh
```

`4G` is the VM disk size. The build downloads Alpine, checks its SHA-512 digest, installs WebShell, configures quotas and cgroups, verifies the guest and powers it off ready to run. It never overwrites an existing disk.

Open http://localhost:8080. Type `new`, choose a password, and save the account UUID. Use the UUID and password to return to the same account. There is no SSH admin port or generated admin key.

## Limits per account

| Resource | Default |
|---|---|
| RAM | 100 MiB |
| Swap | Disabled |
| CPU | Half of one CPU |
| Processes | 100 |
| Disk on the root filesystem | 5 MiB |
| Files and directories on that filesystem | 1024 |

All sessions for one account share these limits. Login refuses to start a shell if limits cannot be applied. Change defaults in `webshell-auth.sh` and the matching expected values in `test-limits.sh`.

`/shared-files` is public and has a sticky bit to prevent removal of other users' files. File permissions still decide who can read or edit them. Shared and social files count toward their owner's quota. Other mounts are not covered by the root disk quota; writes to tmpfs consume memory while allocated by that account.

## Social

Run `social`. Use `j/k` or arrow keys to select a post, `n` to post, `l` to like, `c` to comment, `r` to repost, `v` to read, `d` to hide your own post after confirmation, and `q` to quit.

File ownership determines authorship, not `$USER` or JSON fields. Separate atomic records prevent simultaneous writes from overwriting each other. Likes count once per account. Malformed, oversized, symlinked and publicly writable records are ignored.

Hiding a post does not erase its records or free its disk space. Records are stored under `/var/social/users/<unix-user>/`. Older `/var/social/posts` files are not imported.

## Security and maintenance

This is a shared Unix guest for a trusted small group, not a sandbox between hostile users. Users share the kernel and network. Signup has no global account cap or cross-session rate limit. The host only exposes HTTP on localhost; remote access needs a TLS proxy with access control or a secure tunnel.

Guest upgrades and account recovery require offline maintenance. New source files do not update an already-built VM. Back up the powered-off disk before changing it; rebuilding over it would destroy permanent accounts, so the builder refuses.

For a clean shutdown, press Ctrl+A, then lowercase `c`, type `system_powerdown`, and press Enter in the QEMU monitor. Force-killing QEMU can lose recent writes.

## Checks

```sh
python3 -m unittest discover -s tests -v
sh -n build.sh run.sh webshell-auth.sh test-limits.sh tools/setup-vm.sh tools/start-webshell.sh
```

Inside a session, run `test-limits.sh` for read-only checks of configured limits. These are not CPU, memory or process stress tests.
