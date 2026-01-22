# Installation Guide

> Setting up WebShell on Alpine Linux

---

## Quick Start with Vagrant (Recommended)

```sh
# Install vagrant-qemu plugin
vagrant plugin install vagrant-qemu

# Start WebShell
vagrant up --provider qemu

# Access WebShell at http://localhost:8080
# SSH: vagrant ssh
```

That's it! 🎉

---

## Manual Installation (QEMU)

## 1. Create Virtual Disk

```sh
qemu-img create -f qcow2 webshell.qcow2 64G
```

## 2. Install Alpine Linux

```sh
qemu-system-x86_64 \
    -enable-kvm \
    -m 2048 \
    -nic user,model=virtio \
    -drive file=webshell.qcow2,media=disk,if=virtio \
    -cdrom alpine-virt-3.23.2-x86_64.iso
```

Complete the Alpine installer.

## 3. Enable Disk Quotas

Before rebooting, enable quota support on the root partition:

```sh
apk add e2fsprogs-extra
tune2fs -O quota /dev/vda3
```

Verify quota is enabled:

```sh
tune2fs -l /dev/vda3 | grep 'Filesystem features'
```

Edit `/etc/fstab`:

```
/dev/vda3   /   ext4    defaults,usrjquota=aquota.user,grpjquota=aquota.group,jqfmt=vfsv0    0 1
proc /proc proc defaults,hidepid=2,gid=1001 0 0
```

Reboot, then shut down.

## 4. Boot with SSH

```sh
qemu-system-x86_64 \
    -enable-kvm \
    -m 2048 \
    -nic user,model=virtio,hostfwd=tcp::10022-:22,hostfwd=tcp::8080-:8080 \
    -drive file=webshell.qcow2,media=disk,if=virtio \
    -display none
```

Connect via SSH:

```sh
ssh root@localhost -p 10022
```

## 5. Install Packages

```sh
apk add nano
nano /etc/apk/repositories # uncomment http://dl-cdn.alpinelinux.org/alpine/v3.23/community

apk update && apk add --no-cache \
    bash ttyd sudo shadow nginx supervisor \
    curl nano vim libcgroup cgroup-tools \
    quota-tools py3-passlib
```

## 6. Configure Autostart

```sh
# Quota
cat > /etc/local.d/quotaon.start << 'EOF'
#!/bin/sh
quotaon -av
EOF
chmod +x /etc/local.d/quotaon.start

# Supervisor
cat > /etc/local.d/supervisord.start << 'EOF'
#!/bin/sh
/usr/bin/supervisord -c /etc/supervisord.conf &
EOF
chmod +x /etc/local.d/supervisord.start

# Enable local scripts
rc-update add local default
```

## 7. Create Shared Directory

```sh
mkdir -p /shared-files && chmod 777 /shared-files
# mkdir -p /var/social && chmod 1777 /var/social # Optional
```

## 8. Deploy Scripts

```sh
# Copy webshell-auth.sh to the VM
chmod +x /usr/local/bin/webshell-auth.sh

# Copy supervisord.conf
cp supervisord.conf /etc/supervisord.conf

# Optional copy `tools/social.py` to the VM
chmod +x /usr/local/bin/social
```

## 9. Reboot

```sh
reboot
```

---

WebShell is now available at **http://localhost:8080**
