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

get_monitor_jobs() {
  local target_id="$1"
  # Find the monitor configuration by id
  local monitor_idx
  monitor_idx=$(jq --arg id "$target_id" '.monitors | map(.id == $id) | index(true)' "$CONFIG_PATH")
  if [ -z "$monitor_idx" ] || [ "$monitor_idx" = "null" ]; then
    echo 0
    return
  fi

  local monitor_type
  monitor_type=$(jq -r ".monitors[$monitor_idx].type" "$CONFIG_PATH")

  if [ "$monitor_type" = "github_org" ]; then
    local org token
    org=$(jq -r ".monitors[$monitor_idx].github_org" "$CONFIG_PATH")
    token=$(jq -r ".monitors[$monitor_idx].github_token" "$CONFIG_PATH")

    if [ -z "$org" ] || [ -z "$token" ] || [ "$token" = "YOUR_GITHUB_PERSONAL_ACCESS_TOKEN" ]; then
      if [ "$DRY_RUN" = "true" ]; then
        org="RPDevs-Vault"
        token="dummy_token"
      else
        echo 0
        return
      fi
    fi

    if [ "$DRY_RUN" = "true" ]; then
      local queued="${MOCK_QUEUED_COUNT:-1}"
      local in_progress="${MOCK_IN_PROGRESS_COUNT:-0}"
      echo $((queued + in_progress))
    else
      # Check if gh CLI is available
      if command -v gh >/dev/null 2>&1; then
        local repos
        repos=$(jq -r ".monitors[$monitor_idx].repos[]" "$CONFIG_PATH" 2>/dev/null)
        
        # Fallback to dynamic discovery of top 15 pushed repos if list is empty
        if [ -z "$repos" ] || [ "$repos" = "null" ]; then
          repos=$(GH_TOKEN="$token" gh api "orgs/${org}/repos?sort=pushed&direction=desc&per_page=15" --jq '.[].name' 2>/dev/null)
        fi
        
        if [ -n "$repos" ]; then
          local total_active=0
          local temp_dir
          temp_dir=$(mktemp -d)
          
          for repo in $repos; do
            (
              local q_cnt ip_cnt
              q_cnt=$(GH_TOKEN="$token" gh api "repos/${org}/${repo}/actions/runs?status=queued" --jq '.total_count' 2>/dev/null || echo 0)
              ip_cnt=$(GH_TOKEN="$token" gh api "repos/${org}/${repo}/actions/runs?status=in_progress" --jq '.total_count' 2>/dev/null || echo 0)
              echo $((q_cnt + ip_cnt)) > "$temp_dir/$repo"
            ) &
          done
          wait
          
          for f in "$temp_dir"/*; do
            if [ -f "$f" ]; then
              local cnt
              cnt=$(cat "$f")
              total_active=$((total_active + cnt))
            fi
          done
          rm -rf "$temp_dir"
          echo "$total_active"
          return
        fi
      fi
      
      # Fallback to legacy curl (Note: org runs endpoint returns 404 on modern GitHub)
      local queued_resp in_progress_resp queued_cnt in_progress_cnt
      queued_resp=$(curl -s -H "Authorization: token ${token}" -H "User-Agent: OpenWrt-Runner-Orchestrator" "https://api.github.com/orgs/${org}/actions/runs?status=queued")
      in_progress_resp=$(curl -s -H "Authorization: token ${token}" -H "User-Agent: OpenWrt-Runner-Orchestrator" "https://api.github.com/orgs/${org}/actions/runs?status=in_progress")
      
      queued_cnt=$(echo "$queued_resp" | jq -r '.total_count // 0')
      in_progress_cnt=$(echo "$in_progress_resp" | jq -r '.total_count // 0')
      echo $((queued_cnt + in_progress_cnt))
    fi
  else
    # Unsupported monitor type
    echo 0
  fi
}

run_orchestration() {
  if [ ! -f "$CONFIG_PATH" ]; then
    log_msg "❌ Configuration file not found at $CONFIG_PATH"
    return 1
  fi

  # Parse machines and execute transitions
  MACHINE_COUNT=$(jq '.machines | length' "$CONFIG_PATH")
  MACH_IDX=0

  while [ "$MACH_IDX" -lt "$MACHINE_COUNT" ]; do
    MACH_NAME=$(jq -r ".machines[$MACH_IDX].name" "$CONFIG_PATH")
    MACH_IP=$(jq -r ".machines[$MACH_IDX].ip" "$CONFIG_PATH")
    MACH_MAC=$(jq -r ".machines[$MACH_IDX].mac" "$CONFIG_PATH")
    SSH_USER=$(jq -r ".machines[$MACH_IDX].ssh_user" "$CONFIG_PATH")
    SSH_KEY=$(jq -r ".machines[$MACH_IDX].ssh_key_path" "$CONFIG_PATH")
    SUSPEND_IDLE=$(jq -r ".machines[$MACH_IDX].suspend_idle" "$CONFIG_PATH")

    log_msg "Processing machine ${MACH_NAME} (${MACH_IP})..."

    # Count how many total runners on this machine have active jobs
    RUNNER_COUNT=$(jq ".machines[$MACH_IDX].runners | length" "$CONFIG_PATH")
    RUN_IDX=0
    TOTAL_ACTIVE_RUNNERS=0

    while [ "$RUN_IDX" -lt "$RUNNER_COUNT" ]; do
      CONT_NAME=$(jq -r ".machines[$MACH_IDX].runners[$RUN_IDX].container_name" "$CONFIG_PATH")
      MON_ID=$(jq -r ".machines[$MACH_IDX].runners[$RUN_IDX].monitor_id" "$CONFIG_PATH")

      # Fetch job count for this monitor
      JOB_COUNT=$(get_monitor_jobs "$MON_ID")

      if [ "$JOB_COUNT" -gt 0 ]; then
        TOTAL_ACTIVE_RUNNERS=$((TOTAL_ACTIVE_RUNNERS + 1))
        eval "RUNNER_NEED_RUN_${RUN_IDX}=true"
      else
        eval "RUNNER_NEED_RUN_${RUN_IDX}=false"
      fi

      RUN_IDX=$((RUN_IDX + 1))
    done

    # Check if host is online via ping
    if [ "$DRY_RUN" = "true" ]; then
      PING_STATUS=0
    else
      ping -c 1 -W 2 "$MACH_IP" >/dev/null 2>&1
      PING_STATUS=$?
    fi

    if [ "$PING_STATUS" -eq 0 ]; then
      log_msg "Machine ${MACH_NAME} is ONLINE."

      # Process each runner on this machine
      RUN_IDX=0
      ALL_STOPPED=true
      while [ "$RUN_IDX" -lt "$RUNNER_COUNT" ]; do
        CONT_NAME=$(jq -r ".machines[$MACH_IDX].runners[$RUN_IDX].container_name" "$CONFIG_PATH")
        eval "NEED_RUN=\$RUNNER_NEED_RUN_${RUN_IDX}"

        if [ "$DRY_RUN" = "true" ]; then
          if [ "$NEED_RUN" = "true" ]; then
            CONT_STATE="running"
          else
            CONT_STATE="exited"
          fi
        else
          CONT_STATE=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${MACH_IP}" "docker inspect -f '{{.State.Status}}' ${CONT_NAME}" 2>/dev/null)
        fi

        if [ "$NEED_RUN" = "true" ]; then
          ALL_STOPPED=false
          if [ "$CONT_STATE" != "running" ]; then
            log_msg "Active jobs found for runner container ${CONT_NAME}. Starting container..."
            if [ "$DRY_RUN" = "true" ]; then
              log_msg "[DRY RUN] ssh -i ${SSH_KEY} ${SSH_USER}@${MACH_IP} 'docker start ${CONT_NAME}'"
            else
              ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${MACH_IP}" "docker start ${CONT_NAME}"
            fi
          else
            log_msg "Runner container ${CONT_NAME} is already running."
          fi
        else
          if [ "$CONT_STATE" = "running" ]; then
            log_msg "No active jobs for runner container ${CONT_NAME}. Ensuring container is stopped..."
            if [ "$DRY_RUN" = "true" ]; then
              log_msg "[DRY RUN] ssh -i ${SSH_KEY} ${SSH_USER}@${MACH_IP} 'docker stop ${CONT_NAME}'"
            else
              ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${MACH_IP}" "docker stop ${CONT_NAME} >/dev/null 2>&1"
            fi
          fi
        fi

        RUN_IDX=$((RUN_IDX + 1))
      done

      # Handle suspend if idle and enabled
      if [ "$SUSPEND_IDLE" = "true" ] && [ "$ALL_STOPPED" = "true" ]; then
        if [ "$DRY_RUN" = "true" ]; then
          WHO_COUNT=1
          log_msg "[DRY RUN] Checking active sessions. Mocking WHO_COUNT=1"
        else
          WHO_COUNT=$(ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${MACH_IP}" "who | wc -l" 2>/dev/null)
        fi

        if [ -n "$WHO_COUNT" ] && [ "$WHO_COUNT" -le 1 ]; then
          log_msg "Machine ${MACH_NAME} is idle. Initiating system suspend..."
          if [ "$DRY_RUN" = "true" ]; then
            log_msg "[DRY RUN] ssh -i ${SSH_KEY} ${SSH_USER}@${MACH_IP} 'sudo systemctl suspend'"
          else
            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${MACH_IP}" "sudo systemctl suspend" >/dev/null 2>&1
          fi
        else
          log_msg "Machine ${MACH_NAME} has active user sessions (${WHO_COUNT}). Skipping suspend."
        fi
      fi

    else
      log_msg "Machine ${MACH_NAME} is OFFLINE."

      # If there is at least one runner that needs to run, boot the machine via Wake-on-LAN
      if [ "$TOTAL_ACTIVE_RUNNERS" -gt 0 ]; then
        log_msg "Active jobs found for machine ${MACH_NAME}! Broadcasting WoL magic packet to ${MACH_MAC}..."
        if [ "$DRY_RUN" = "true" ]; then
          log_msg "[DRY RUN] etherwake ${MACH_MAC}"
        else
          if command -v etherwake >/dev/null 2>&1; then
            etherwake "$MACH_MAC"
          elif command -v wol >/dev/null 2>&1; then
            wol "$MACH_MAC"
          else
            log_msg "❌ Neither etherwake nor wol commands were found on this router."
          fi
        fi

        # Wait loop for host to come up
        BOOT_TIMEOUT=120
        ELAPSED=0
        log_msg "Waiting for machine ${MACH_NAME} to boot..."
        while [ "$ELAPSED" -lt "$BOOT_TIMEOUT" ]; do
          ping -c 1 -W 2 "$MACH_IP" >/dev/null 2>&1
          if [ $? -eq 0 ]; then
            log_msg "Machine ${MACH_NAME} successfully booted!"
            sleep 5
            
            # Start all runner containers that need to run
            RUN_IDX=0
            while [ "$RUN_IDX" -lt "$RUNNER_COUNT" ]; do
              CONT_NAME=$(jq -r ".machines[$MACH_IDX].runners[$RUN_IDX].container_name" "$CONFIG_PATH")
              eval "NEED_RUN=\$RUNNER_NEED_RUN_${RUN_IDX}"
              if [ "$NEED_RUN" = "true" ]; then
                log_msg "Starting runner container ${CONT_NAME}..."
                if [ "$DRY_RUN" = "true" ]; then
                  log_msg "[DRY RUN] ssh -i ${SSH_KEY} ${SSH_USER}@${MACH_IP} 'docker start ${CONT_NAME}'"
                else
                  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${MACH_IP}" "docker start ${CONT_NAME}"
                fi
              fi
              RUN_IDX=$((RUN_IDX + 1))
            done
            break
          fi
          sleep 5
          ELAPSED=$((ELAPSED + 5))
        done

        if [ "$ELAPSED" -ge "$BOOT_TIMEOUT" ]; then
          log_msg "❌ Timeout waiting for machine ${MACH_NAME} to boot."
        fi
      fi
    fi

    MACH_IDX=$((MACH_IDX + 1))
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
