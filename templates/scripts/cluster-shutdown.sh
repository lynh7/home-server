#!/bin/bash
set -e

MASTER_NODE_0="10.10.0.30"
MASTER_NODE_1="10.10.0.31"
MASTER_NODE_2="10.10.0.32"
WORKER_NODE_1="10.10.0.34"
WORKER_NODE_2="10.10.0.35"

function log() {
  echo -e "\033[1;32m[STARTUP]\033[0m $1"
}

function shutdown_log() {
  echo -e "\033[1;33m[SHUTDOWN]\033[0m $1"
}

function shutdown_cluster() {
  clear
  shutdown_log "Shutting down cluster (VMs only)..."
  
  # Check if worker node 1 is reachable before attempting shutdown
  shutdown_log "1️⃣  Checking worker node 1 connectivity..."
  if talosctl --nodes $WORKER_NODE_1 version &> /dev/null; then
    shutdown_log "   Draining workloads from worker node 1..."
    talosctl shutdown --nodes $WORKER_NODE_1  || {
      shutdown_log "Worker node 1 shutdown failed"
    }
  else
    shutdown_log "   Worker node 1 is already stopped or unreachable, skipping..."
  fi
  
  # Check if worker node 2 is reachable before attempting shutdown
  shutdown_log "2️⃣  Checking worker node 2 connectivity..."
  if talosctl --nodes $WORKER_NODE_2 version  &> /dev/null; then
    shutdown_log "   Draining workloads from worker node 2..."
    talosctl shutdown --nodes $WORKER_NODE_2  || {
      shutdown_log "Worker node 2 shutdown failed"
    }
  else
    shutdown_log "   Worker node 2 is already stopped or unreachable, skipping..."
  fi
  
  shutdown_log "3️⃣  Waiting 20 seconds to allow workers to stop gracefully..."
  sleep 20
  
  shutdown_log "4️⃣  Checking master nodes connectivity..."
  
  if talosctl --nodes $MASTER_NODE_2 version &> /dev/null; then
    shutdown_log "   Shutting down master node 2..."
    talosctl shutdown --nodes $MASTER_NODE_2  || {
      shutdown_log "Master node 2 shutdown failed"
    }
  else
    shutdown_log "   Master node 2 is already stopped or unreachable, skipping..."
  fi
  
  if talosctl --nodes $MASTER_NODE_1 version &> /dev/null; then
    shutdown_log "   Shutting down master node 1..."
    talosctl shutdown --nodes $MASTER_NODE_1  || {
      shutdown_log "Master node 1 shutdown failed"
    }
  else
    shutdown_log "   Master node 1 is already stopped or unreachable, skipping..."
  fi
  
  if talosctl --nodes $MASTER_NODE_0 version &> /dev/null; then
    shutdown_log "   Shutting down master node 0..."
    talosctl shutdown --nodes $MASTER_NODE_0  || {
      shutdown_log "Master node 0 shutdown failed"
    }
  else
    shutdown_log "   Master node 0 is already stopped or unreachable, skipping..."
  fi
  
  shutdown_log "✅ All Talos nodes shutdown sequence completed."
  shutdown_log "ℹ️  You can monitor shutdown status in Proxmox or using 'talosctl dmesg --nodes <ip>'."
  echo ""
}

# Main execution
shutdown_cluster