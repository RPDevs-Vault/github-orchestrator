#!/bin/sh
# runner_orchestrator.sh - OpenWrt Router-Based Runner Lifecycle Orchestrator
# Checks GitHub API for queued/active actions and boots/suspends docker runners accordingly.

CONFIG_PATH="/etc/runner_orchestrator/config.json"
# Local fallback for testing
if [ ! -f "$CONFIG_PATH" ] && [ -f "./config.json" ]; then
  CONFIG_PATH="./config.json"
fi

if [ ! -f "$CONFIG_PATH" ] && [ -f "./config.json.template" ]; then
  CONFIG_PATH="./config.json.template"
fi

if [ ! -f "$CONFIG_PATH" ] && [ -f "./router/config.json.template" ]; then
  CONFIG_PATH="./router/config.json.template"
fi

# Dry Run flag
DRY_RUN="${DRY_RUN:-false}"

log_msg() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Parse options
RUN_DAEMON=false
for arg in "$@"; do
  if [ "$arg" = "--daemon" ] || [ "$arg" = "-d" ]; then
    RUN_DAEMON=true
  fi
done

run_orchestration() {
  if [ ! -f "$CONFIG_PATH" ]; then
    log_msg "❌ Configuration file not found at $CONFIG_PATH"
    return 1
  fi

  # Load global variables from configuration using jq
  GITHUB_ORG=$(jq -r '.github_org' "$CONFIG_PATH")
  GITHUB_TOKEN=$(jq -r '.github_token' "$CONFIG_PATH")

  if [ -z "$GITHUB_ORG" ] || [ -z "$GITHUB_TOKEN" ] || [ "$GITHUB_TOKEN" = "YOUR_GITHUB_PERSONAL_ACCESS_TOKEN" ]; then
    log_msg "⚠️ Invalid or default GITHUB_TOKEN/GITHUB_ORG in configuration."
    # Set dummy values for dry-runs if we are running in dry-run mode
    if [ "$DRY_RUN" = "true" ]; then
      GITHUB_ORG="RPDevs-Vault"
      GITHUB_TOKEN="dummy_token"
    else
      return 1
    fi
  fi

  # Check GitHub API for active organization runs (queued or in-progress)
  log_msg "Checking GitHub organization runs for ${GITHUB_ORG}..."
  if [ "$DRY_RUN" = "true" ]; then
    # Mock count for dry-run verification
    QUEUED_COUNT="${MOCK_QUEUED_COUNT:-1}"
    IN_PROGRESS_COUNT="${MOCK_IN_PROGRESS_COUNT:-0}"
    log_msg "[DRY RUN] Mocking ${QUEUED_COUNT} queued run, ${IN_PROGRESS_COUNT} in-progress runs."
  else
    QUEUED_RESPONSE=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" -H "User-Agent: OpenWrt-Runner-Orchestrator" "https://api.github.com/orgs/${GITHUB_ORG}/actions/runs?status=queued")
    IN_PROGRESS_RESPONSE=$(curl -s -H "Authorization: token ${GITHUB_TOKEN}" -H "User-Agent: OpenWrt-Runner-Orchestrator" "https://api.github.com/orgs/${GITHUB_ORG}/actions/runs?status=in_progress")

    QUEUED_COUNT=$(echo "$QUEUED_RESPONSE" | jq -r '.total_count // 0')
    IN_PROGRESS_COUNT=$(echo "$IN_PROGRESS_RESPONSE" | jq -r '.total_count // 0')
  fi

  ACTIVE_JOBS=$((QUEUED_COUNT + IN_PROGRESS_COUNT))
  log_msg "Active Jobs in Fleet Queue: ${ACTIVE_JOBS} (Queued: ${QUEUED_COUNT}, In-Progress: ${IN_PROGRESS_COUNT})"

  # Parse host configs and execute transitions
  HOST_COUNT=$(jq '.hosts | length' "$CONFIG_PATH")
  INDEX=0

  while [ "$INDEX" -lt "$HOST_COUNT" ]; do
    HOST_NAME=$(jq -r ".hosts[$INDEX].name" "$CONFIG_PATH")
    HOST_IP=$(jq -r ".hosts[$INDEX].ip" "$CONFIG_PATH")
    HOST_MAC=$(jq -r ".hosts[$INDEX].mac" "$CONFIG_PATH")
    SSH_USER=$(jq -r ".hosts[$INDEX].ssh_user" "$CONFIG_PATH")
    SSH_KEY=$(jq -r ".hosts[$INDEX].ssh_key_path" "$CONFIG_PATH")
    CONTAINER_NAME=$(jq -r ".hosts[$INDEX].container_name" "$CONFIG_PATH")
    SUSPEND_IDLE=$(jq -r ".hosts[$INDEX].suspend_idle" "$CONFIG_PATH")

    log_msg "Processing host ${HOST_NAME} (${HOST_IP})..."

    # Check if host is online via ping
    if [ "$DRY_RUN" = "true" ]; then
      PING_STATUS=0
    else
      ping -c 1 -W 2 "$HOST_IP" >/dev/null 2>&1
      PING_STATUS=$?
    fi

    if [ "$PING_STATUS" -eq 0 ]; then
      log_msg "Host ${HOST_NAME} is ONLINE."

      # Check target container status
      if [ "$DRY_RUN" = "true" ]; then
        CONTAINER_STATE="running"
      else
        CONTAINER_STATE=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${HOST_IP}" "docker inspect -f '{{.State.Status}}' ${CONTAINER_NAME}" 2>/dev/null)
      fi

      if [ "$ACTIVE_JOBS" -gt 0 ]; then
        if [ "$CONTAINER_STATE" != "running" ]; then
          log_msg "Active jobs found. Booting/starting container ${CONTAINER_NAME}..."
          if [ "$DRY_RUN" = "true" ]; then
            log_msg "[DRY RUN] ssh -i ${SSH_KEY} ${SSH_USER}@${HOST_IP} 'docker start ${CONTAINER_NAME}'"
          else
            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${HOST_IP}" "docker start ${CONTAINER_NAME}"
          fi
        else
          log_msg "Container ${CONTAINER_NAME} is already running."
        fi
      else
        if [ "$CONTAINER_STATE" = "running" ]; then
          log_msg "No active jobs. Ensuring container ${CONTAINER_NAME} is stopped..."
          if [ "$DRY_RUN" = "true" ]; then
            log_msg "[DRY RUN] ssh -i ${SSH_KEY} ${SSH_USER}@${HOST_IP} 'docker stop ${CONTAINER_NAME}'"
          else
            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${HOST_IP}" "docker stop ${CONTAINER_NAME} >/dev/null 2>&1"
          fi
        fi

        if [ "$SUSPEND_IDLE" = "true" ]; then
          # Check active non-orchestration SSH sessions
          if [ "$DRY_RUN" = "true" ]; then
            WHO_COUNT=1
            log_msg "[DRY RUN] Checking active sessions. Mocking WHO_COUNT=1"
          else
            WHO_COUNT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${HOST_IP}" "who | wc -l" 2>/dev/null)
          fi

          # If only 1 session (our check session itself or empty) we consider it idle
          if [ -n "$WHO_COUNT" ] && [ "$WHO_COUNT" -le 1 ]; then
            log_msg "Host ${HOST_NAME} is idle. Initiating system suspend..."
            if [ "$DRY_RUN" = "true" ]; then
              log_msg "[DRY RUN] ssh -i ${SSH_KEY} ${SSH_USER}@${HOST_IP} 'sudo systemctl suspend'"
            else
              ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${HOST_IP}" "sudo systemctl suspend" >/dev/null 2>&1
            fi
          else
            log_msg "Host ${HOST_NAME} has active user sessions (${WHO_COUNT}). Skipping suspend."
          fi
        fi
      fi
    else
      log_msg "Host ${HOST_NAME} is OFFLINE."

      if [ "$ACTIVE_JOBS" -gt 0 ]; then
        log_msg "Active jobs found! Broadcasting WoL magic packet to ${HOST_MAC}..."
        if [ "$DRY_RUN" = "true" ]; then
          log_msg "[DRY RUN] etherwake ${HOST_MAC}"
        else
          if command -v etherwake >/dev/null 2>&1; then
            etherwake "$HOST_MAC"
          elif command -v wol >/dev/null 2>&1; then
            wol "$HOST_MAC"
          else
            log_msg "❌ Neither etherwake nor wol commands were found on this router."
          fi
        fi

        # Wait loop for host to come up
        BOOT_TIMEOUT=120
        ELAPSED=0
        log_msg "Waiting for host ${HOST_NAME} to boot..."
        while [ "$ELAPSED" -lt "$BOOT_TIMEOUT" ]; do
          ping -c 1 -W 2 "$HOST_IP" >/dev/null 2>&1
          if [ $? -eq 0 ]; then
            log_msg "Host ${HOST_NAME} successfully booted!"
            sleep 5
            log_msg "Starting container ${CONTAINER_NAME}..."
            if [ "$DRY_RUN" = "true" ]; then
              log_msg "[DRY RUN] ssh -i ${SSH_KEY} ${SSH_USER}@${HOST_IP} 'docker start ${CONTAINER_NAME}'"
            else
              ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${HOST_IP}" "docker start ${CONTAINER_NAME}"
            fi
            break
          fi
          sleep 5
          ELAPSED=$((ELAPSED + 5))
        done

        if [ "$ELAPSED" -ge "$BOOT_TIMEOUT" ]; then
          log_msg "❌ Timeout waiting for host ${HOST_NAME} to boot."
        fi
      fi
    fi

    INDEX=$((INDEX + 1))
  done

  log_msg "Lifecycle processing complete."
}

if [ "$RUN_DAEMON" = "true" ]; then
  log_msg "Starting OpenWrt Runner Lifecycle Orchestrator Daemon..."
  while true; do
    run_orchestration
    # Get sleep interval from config, default to 60
    POLLING_INTERVAL=60
    if [ -f "$CONFIG_PATH" ]; then
      POLLING_INTERVAL=$(jq -r '.polling_interval_seconds // 60' "$CONFIG_PATH")
    fi
    sleep "$POLLING_INTERVAL"
  done
else
  run_orchestration
fi
