# -*- mode: ruby -*-
# vi: set ft=ruby :

# ============================================================
#                    WebShell Vagrantfile
# ============================================================
# Usage:
#   vagrant plugin install vagrant-qemu
#   vagrant up --provider qemu
#   
# Access WebShell at: http://localhost:8080
# SSH access: vagrant ssh
# ============================================================

Vagrant.configure("2") do |config|
  # Use Alpine Linux box (or create from local qcow2)
  config.vm.box = "generic/alpine318"
  config.vm.box_check_update = false

  # VM hostname
  config.vm.hostname = "webshell"

  # Port forwarding
  config.vm.network "forwarded_port", guest: 8080, host: 8080  # WebShell (ttyd)
  config.vm.network "forwarded_port", guest: 22, host: 10022   # SSH

  # Disable default synced folder (we'll use our own setup)
  config.vm.synced_folder ".", "/vagrant", disabled: true

  # QEMU provider configuration
  config.vm.provider "qemu" do |qe|
    # x86_64 configuration for Linux hosts with KVM
    qe.arch = "x86_64"
    qe.machine = "q35,accel=kvm"
    qe.cpu = "host"
    qe.smp = "2"
    qe.memory = "2G"
    qe.net_device = "virtio-net-pci"
    
    # SSH settings
    qe.ssh_port = 50022
    
    # QEMU directory (adjust if needed)
    qe.qemu_dir = "/usr/share/qemu"
    
    # Disk resize (64GB, adjust if needed)
    qe.disk_resize = "4G"
  end

  # ============================================================
  # Provisioning Scripts
  # ============================================================

  # Step 1: Install required packages
  config.vm.provision "packages", type: "shell", inline: <<-SHELL
    echo "==> Installing packages..."
    
    # Enable community repository
    sed -i 's/#.*community/community/' /etc/apk/repositories
    
    apk update && apk add --no-cache \
      bash \
      ttyd \
      sudo \
      shadow \
      supervisor \
      curl \
      nano \
      vim \
      cgroup-tools \
      quota-tools \
      py3-passlib \
      e2fsprogs-extra
    
    echo "==> Packages installed successfully"
  SHELL

  # Step 2: Configure cgroups v2
  config.vm.provision "cgroups", type: "shell", inline: <<-SHELL
    echo "==> Configuring cgroups v2..."
    
    # Ensure cgroup2 is mounted
    if ! mountpoint -q /sys/fs/cgroup; then
      mount -t cgroup2 none /sys/fs/cgroup
    fi
    
    # Enable controllers
    echo "+memory +cpu +pids" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
    
    echo "==> cgroups v2 configured"
  SHELL

  # Step 3: Setup shared directory
  config.vm.provision "shared-dir", type: "shell", inline: <<-SHELL
    echo "==> Creating shared directory..."
    mkdir -p /shared-files
    chmod 1777 /shared-files
    echo "==> Shared directory created"
  SHELL

  # Step 4: Deploy webshell-auth.sh
  config.vm.provision "webshell-auth", type: "file", 
    source: "webshell-auth.sh", 
    destination: "/tmp/webshell-auth.sh"

  config.vm.provision "install-auth", type: "shell", inline: <<-SHELL
    echo "==> Installing webshell-auth.sh..."
    mv /tmp/webshell-auth.sh /usr/local/bin/webshell-auth.sh
    chmod +x /usr/local/bin/webshell-auth.sh
    echo "==> webshell-auth.sh installed"
  SHELL

#   # Step 5: Deploy test-limits.sh (optional)
#   config.vm.provision "test-limits", type: "file", 
#     source: "test-limits.sh", 
#     destination: "/tmp/test-limits.sh"

#   config.vm.provision "install-tests", type: "shell", inline: <<-SHELL
#     echo "==> Installing test-limits.sh..."
#     mv /tmp/test-limits.sh /usr/local/bin/test-limits.sh
#     chmod +x /usr/local/bin/test-limits.sh
#     echo "==> test-limits.sh installed"
#   SHELL

  # Step 6: Configure supervisord
  config.vm.provision "supervisord", type: "shell", inline: <<-SHELL
    echo "==> Configuring supervisord..."
    
    cat > /etc/supervisord.conf << 'EOF'
[supervisord]
nodaemon=true
user=root

[program:ttyd]
command=ttyd --port 8080 --writable /usr/local/bin/webshell-auth.sh
autostart=true
autorestart=true
stderr_logfile=/var/log/ttyd.err.log
stdout_logfile=/var/log/ttyd.out.log
EOF

    echo "==> supervisord configured"
  SHELL

  # Step 7: Configure autostart services
  config.vm.provision "autostart", type: "shell", inline: <<-SHELL
    echo "==> Configuring autostart services..."
    
    # Create supervisord autostart script
    cat > /etc/local.d/supervisord.start << 'EOF'
#!/bin/sh
/usr/bin/supervisord -c /etc/supervisord.conf &
EOF
    chmod +x /etc/local.d/supervisord.start
    
    # Enable local scripts on boot
    rc-update add local default 2>/dev/null || true
    
    echo "==> Autostart configured"
  SHELL

  # Step 8: Start services
  config.vm.provision "start-services", type: "shell", run: "always", inline: <<-SHELL
    echo "==> Starting WebShell services..."
    
    # Kill any existing supervisord
    pkill supervisord 2>/dev/null || true
    sleep 1
    
    # Start supervisord in background
    /usr/bin/supervisord -c /etc/supervisord.conf &
    
    echo ""
    echo "============================================================"
    echo "  WebShell is now running!"
    echo "============================================================"
    echo "  Access WebShell at: http://localhost:8080"
    echo "  SSH access: vagrant ssh"
    echo "============================================================"
  SHELL
end
