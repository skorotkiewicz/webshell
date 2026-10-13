# QEMU setup

Use [INSTALL.md](INSTALL.md) for installation, quotas, cgroups and deployment. It replaces the older commands in this file.

The VM disk is `webshell.qcow2` in the repository root. Start it with:

```sh
sh qemu-os-virt/run.sh
```

Connect to the guest with `ssh root@localhost -p 10022`. Open the terminal at http://localhost:8080. Forwarded ports bind only to localhost.

Removing an SSH client does not block outbound SSH. Users can install or copy another client. Network restrictions require firewall rules, not package removal. This project does not isolate each account's network access.
