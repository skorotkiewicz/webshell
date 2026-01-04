# create disk
$ qemu-img create -f qcow2 webshell.qcow2 64G

# install
$ qemu-system-x86_64 \
    -enable-kvm \
    -m 2048 \
    -nic user,model=virtio \
    -drive file=webshell.qcow2,media=disk,if=virtio \
    -cdrom alpine-virt-3.23.2-x86_64.iso

# change drive to enable quota
apk add e2fsprogs-extra
tune2fs -O quota /dev/vda3
tune2fs -l /dev/vda3 | grep 'Filesystem features' # check if there is "quota"

# edit /etc/fstab
/dev/vda3   /   ext4    defaults,usrjquota=aquota.user,grpjquota=aquota.group,jqfmt=vfsv0    0 1
proc /proc proc defaults,hidepid=2,gid=1001 0 0

# start ssh
$ qemu-system-x86_64 \
    -enable-kvm \
    -m 2048 \
    -nic user,model=virtio,hostfwd=tcp::10022-:22,hostfwd=tcp::8080-:8080 \
    -drive file=webshell.qcow2,media=disk,if=virtio \
    -display none

#
# ssh root@localhost -p 10022
#

# install apks
$ apk update && apk add --no-cache \
    bash \
    ttyd \
    sudo \
    shadow \
    nginx \
    supervisor \
    curl \
    nano \
    vim \
    libcgroup \
    cgroup-tools \
    quota-tools \
    py3-passlib


# autostart quota
$ nano /etc/local.d/quotaon.start
#!/bin/sh
quotaon -av

$ chmod +x /etc/local.d/quotaon.start

# autostart supervisord
$ nano /etc/local.d/supervisord.start
#!/bin/sh
/usr/bin/supervisord -c /etc/supervisord.conf &

$ chmod +x /etc/local.d/supervisord.start

# autostart everting /etc/local.d/*.start
$ rc-update add local default

# create shared files
$ mkdir -p /shared-files && chmod 777 /shared-files

# create webshell-auth.sh
$ nano /usr/local/bin/webshell-auth.sh
$ chmod +x /usr/local/bin/webshell-auth.sh

# create supervisord.conf
$ nano /etc/supervisord.conf
$ #/usr/bin/supervisord -c /etc/supervisord.conf

# reboot
$ reboot

# test limits
$ apk add gcc musl-dev
$ ./test-limits.sh

# disable ssh
> block all outgoing ssh connections, but allow {USERNAME} to perform it.

```
apk del openssh-client
apk add openssh-server
rc-update add sshd default
rc-service sshd start
 
iptables -A OUTPUT -o eth0  -p tcp --destination-port 22 -m owner --uid-owner {USERNAME} -j ACCEPT
iptables -A OUTPUT -o eth0 -p tcp --destination-port 22 -j DROP
```

<!-- > /dev/null 2>&1 -->