# 🔌 OpenWrt Router-Based Runner Orchestrator

This repository contains the configuration, installation documentation, and orchestration script to automatically manage the lifecycle (power state and docker execution) of GitHub self-hosted runners on physical target machines.

It features a decoupled architecture supporting multiple monitors (e.g. GitHub Organizations) mapped to specific runner containers on multiple physical/virtual machines.

---

## 🚀 How it Works

1. **Check Monitors**: The orchestrator daemon polls all configured monitor sources (e.g., GitHub Organizations) via API to check for queued or in-progress workflow runs.
2. **Wake Target Machines (WoL)**: If any monitor has active jobs, the script identifies which machines host the corresponding runner containers. If those machines are offline, it broadcasts **Wake-on-LAN (WoL)** packets to boot them.
3. **Start Active Runners**: Once the machines are online, the daemon SSHes into them and starts only the runner containers associated with the active monitor queues.
4. **Stop Idle Runners & Suspend**: When a monitor has no active/queued runs, the daemon stops the corresponding runner containers on the hosts. If all runner containers on a machine are stopped/idle, and `suspend_idle` is enabled (with no active SSH users), it suspends the machine to save power.


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

