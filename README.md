# 🔌 OpenWrt Router-Based Runner Orchestrator

This subdirectory contains the configuration, installation documentation, and orchestration script to automatically manage the power state and docker execution of GitHub self-hosted runners on physical hosts `llmadmin01` (10.0.0.100) and `t430` (10.0.0.101).

---

## 🚀 How it Works

1. **Check Queue**: The orchestrator script polls the GitHub API every minute checking for `queued` workflows inside the organization.
2. **Wake Hosts (WoL)**: If there are queued jobs and the target docker hosts are offline (unreachable via ping), the router broadcasts a **Wake-on-LAN (WoL)** packet to boot the physical machines.
3. **Start Runners**: Once the hosts are online, the router SSHes into the target hosts and boots the Docker runner container (`action-runner-prod`).
4. **Idle Suspend**: When the queue is clear and no runners are actively processing jobs, the router stops the containers and issues a secure `systemctl suspend` command to the physical hosts to save power.

---

## 🛠️ OpenWrt Installation

### 1. Install System Dependencies
Connect to your OpenWrt router via SSH and run:
```bash
opkg update
opkg install curl jq etherwake dropbear
```

### 2. Configure Directory and Config
Create the configuration folder on your router:
```bash
mkdir -p /etc/runner_orchestrator
```
Copy `config.json.template` to `/etc/runner_orchestrator/config.json` on the router, and populate it with your GitHub PAT, host MAC addresses, and SSH credentials.

### 3. SSH Key Setup
Generate a dedicated SSH keypair on the router if you don't already have one:
```bash
dropbearkey -t rsa -f /etc/runner_orchestrator/id_rsa
# Extract the public key to authorize it on target hosts:
dropbearkey -y -f /etc/runner_orchestrator/id_rsa
```
Add this public key output to `/home/llmadmin/.ssh/authorized_keys` on both target machines (`llmadmin01` and `t430`).

### 4. Deploy the Script
Copy `runner_orchestrator.sh` to `/etc/runner_orchestrator/runner_orchestrator.sh` and make it executable:
```bash
chmod +x /etc/runner_orchestrator/runner_orchestrator.sh
```

### 5. Setup procd Daemon Service (`github-orchestrator`)
Instead of using cron, run the orchestrator as a persistent service daemon supervised by OpenWrt's native `procd`.

1. Create a service script `/etc/init.d/github-orchestrator` with the following content:
```sh
#!/bin/sh /etc/rc.common

START=99
USE_PROCD=1

EXTRA_COMMANDS="status"
EXTRA_HELP="        status  Check the status of the daemon"

start_service() {
        procd_open_instance
        procd_set_param command /usr/bin/runner_orchestrator.sh --daemon
        procd_set_param respawn
        procd_set_param stdout 1
        procd_set_param stderr 1
        procd_close_instance
}

status_service() {
        if pgrep -f "runner_orchestrator.sh --daemon" >/dev/null; then
                echo "github-orchestrator is running (PID: \$(pgrep -f "runner_orchestrator.sh --daemon" | head -n 1))"
                echo "Recent log output:"
                logread | grep runner_orchestrator.sh | tail -n 5
        else
                echo "github-orchestrator is stopped"
        fi
}
```

2. Make the init script executable, enable it to start on boot, and start it:
```bash
chmod +x /etc/init.d/github-orchestrator
/etc/init.d/github-orchestrator enable
/etc/init.d/github-orchestrator start
```

3. You can verify the daemon state and recent logs at any time by running:
```bash
/etc/init.d/github-orchestrator status
```

