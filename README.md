# WebShell

A browser terminal for a small group, running Alpine Linux inside QEMU. Accounts and files survive reconnects and VM restarts because they live on `webshell.qcow2`.

Type `new`, choose a password, and save the account UUID shown once at signup. Use that UUID and password to return to the same Unix account and home. Existing account UUIDs still work.

## Build and run

Install the host tools listed in [INSTALL.md](INSTALL.md), then:

```sh
./build.sh 4G
./run.sh
```

The build downloads Alpine and configures everything automatically. `4G` is the VM disk size; the guest uses 2 GiB of RAM. Existing disks are never overwritten.

Open http://localhost:8080. Admin access is `ssh -i ./webshell-key -p 10022 root@localhost`. Neither host port listens on the public network by default.

## Limits

| Per account, across all its sessions | Default |
|---|---|
| Memory | 100 MiB |
| Swap | Disabled |
| CPU | Half of one CPU |
| Processes | 100 |
| Disk on the root filesystem | 5 MiB |
| Files and directories on that filesystem | 1024 |

Change defaults in `webshell-auth.sh` and the expected values in `test-limits.sh`. Login refuses to start a shell if cgroups or disk quotas are unavailable.

New homes are private. `/shared-files` is public, with a sticky bit that prevents other users from removing your files. File permissions still decide who can read or edit them. Shared files and social records count toward their owner's disk quota.

## Local social

Run `social` in a session. Use `j/k` or arrow keys to select a post, `n` to write, `l` to like, `c` to comment, `r` to repost, `v` to read, and `d` to hide your own post after confirmation. `q` exits.

Records live in `/var/social/users/<unix-user>/`. File ownership determines authorship, not `$USER` or a JSON field. Likes count once per account. Separate records prevent simultaneous comments or posts from overwriting each other. Malformed records and symlinks are skipped.

Hiding a post adds a record; it does not erase its contents. Old `/var/social/posts` and `users.json` files stay untouched but are not imported into the new feed.

## Security boundary

This is a shared Unix system inside a VM, not a sandbox between hostile users. Users share the guest kernel, network and public files. Cgroups limit resources, not filesystem or network access. Signup is open and has no global account cap or cross-session rate limit. Keep this for a trusted small group.

For remote access, use an SSH tunnel or a TLS reverse proxy with access control. Do not expose plain HTTP to the Internet. Keep Alpine patched and back up the powered-off VM disk. Losing the account UUID or password requires administrator help; there is no self-service recovery.

## Checks

```sh
python3 -m unittest discover -s tests -v
sh -n build.sh run.sh webshell-auth.sh test-limits.sh tools/setup-vm.sh tools/start-webshell.sh
```

Inside a deployed session, run `sh test-limits.sh` for read-only quota and cgroup checks. These verify configured values, not a stress test of kernel enforcement.
