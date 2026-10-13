# Install on Alpine Linux

Run guest commands as root unless a step says host. This setup assumes an ext4 root filesystem on `/dev/vda3`; check your device before changing filesystem features. Keep the VM disk in the repository root.

## 1. Create and install the VM

On the host, obtain an Alpine 3.23 virtual ISO, for example `curl -fL -o alpine.iso <official-ISO-URL>`.

```sh
qemu-img create -f qcow2 webshell.qcow2 64G
qemu-system-x86_64 \
    -enable-kvm -m 2048 \
    -nic user,model=virtio \
    -drive file=webshell.qcow2,media=disk,if=virtio \
    -cdrom alpine.iso
```

Install Alpine to the disk, enable SSH for administration, and configure a root password. Enable the matching `community` repository in `/etc/apk/repositories`.

## 2. Enable quotas and cgroups

For ext4 internal quotas, enable the quota feature while the installed root partition is **unmounted**, for example after booting the installer ISO again. Do not run `tune2fs` against an unknown or mounted device.

```sh
apk add e2fsprogs-extra
tune2fs -O quota -Q usrquota /dev/vda3
```

Boot the installed system. Its root entry in `/etc/fstab` should use `usrquota`; do not mix internal quotas with the old `aquota.user` configuration:

```text
/dev/vda3 / ext4 defaults,usrquota 0 1
```

Enable unified cgroups in `/etc/rc.conf`:

```text
rc_cgroup_mode="unified"
```

Install the guest packages.

```sh
apk update
apk add \
    ttyd shadow supervisor quota-tools python3 py3-passlib
rc-update add cgroups default
rc-service cgroups start
quotaon -av
quotaon -p /
cat /sys/fs/cgroup/cgroup.controllers
```

`quotaon -p /` must report user quotas are on. The controllers must include `memory cpu pids`. Reboot after filesystem or cgroup changes if needed.

Optional process privacy uses `proc /proc proc defaults,hidepid=2 0 0` in `/etc/fstab`. It does not isolate users from the guest kernel.

## 3. Start with local host forwarding

Shut down the guest, then run on the host:

```sh
sh qemu-os-virt/run.sh
ssh root@localhost -p 10022
```

Ports 10022 and 8080 bind only to host localhost. For access from another computer, tunnel port 8080 over SSH rather than opening plain HTTP.

## 4. Deploy

From the repository on the host:

```sh
scp -P 10022 webshell-auth.sh root@localhost:/usr/local/bin/webshell-auth.sh
scp -P 10022 tools/social.py root@localhost:/usr/local/bin/social
scp -P 10022 supervisord.conf root@localhost:/etc/supervisord.conf
scp -P 10022 test-limits.sh root@localhost:/usr/local/bin/test-limits.sh
```

In the guest:

```sh
chown root:root /usr/local/bin/webshell-auth.sh /usr/local/bin/social
chmod 755 /usr/local/bin/webshell-auth.sh /usr/local/bin/social /usr/local/bin/test-limits.sh
mkdir -p /shared-files /var/social /var/social/users
chown root:root /shared-files /var/social /var/social/users
chmod 1777 /shared-files
chmod 755 /var/social /var/social/users

cat > /etc/local.d/quotaon.start <<'EOF'
#!/bin/sh
quotaon -av
EOF
cat > /etc/local.d/supervisord.start <<'EOF'
#!/bin/sh
/usr/bin/supervisord -c /etc/supervisord.conf &
EOF
chmod 755 /etc/local.d/quotaon.start /etc/local.d/supervisord.start
rc-update add local default
reboot
```

Open http://localhost:8080, create an account, save the UUID, disconnect, and log in again. Check a saved file survives reconnecting and a VM reboot. Run `test-limits.sh` inside the user session.

## Existing installations

Back up the powered-off VM disk before upgrading. Account names and password hashes are retained. Existing `.profile` files are no longer overwritten. Existing home permissions are retained; an administrator can set those account homes to mode 700 after checking they are real directories.

Check `/shared-files`, `/var/social` and `/var/social/users` are real directories, not symlinks, before running the ownership commands above. The authentication script refuses non-root-owned shared parents rather than trusting user-created storage. Old social posts remain on disk but are not migrated. No account or home is automatically removed on failure.

An interrupted signup may leave a locked Unix account that an administrator must inspect. Signup is not suitable for untrusted public access. Quotas cover only the root filesystem, not additional mounts such as tmpfs; memory-backed writes are subject to cgroup memory limits while allocated by that account.
