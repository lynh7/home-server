#!/bin/bash
set -e

MASTER_NODE_1="10.10.0.30"
MASTER_NODE_2="10.10.0.31"
MASTER_NODE_3="10.10.0.32"
WORKER_NODE_1="10.10.0.34"
WORKER_NODE_2="10.10.0.35"


function log() {
  echo -e "\033[1;32m[STARTUP]\033[0m $1"
}

function error_log() {
  echo -e "\033[1;31m[ERROR]\033[0m $1"
}

function shutdown_log() {
  echo -e "\033[1;33m[SHUTDOWN]\033[0m $1"
}

# Check if dialog is available, fallback to whiptail
if command -v dialog &> /dev/null; then
  DIALOG="dialog"
elif command -v whiptail &> /dev/null; then
  DIALOG="whiptail"
else
  echo "Neither dialog nor whiptail found. Installing dialog..."
  sudo apt-get update && sudo apt-get install -y dialog
  DIALOG="dialog"
fi

function show_menu() {
  if [ "$DIALOG" = "dialog" ]; then
    choice=$(dialog --clear --backtitle "Proxmox Cluster Management" \
      --title "Main Menu" \
      --menu "Choose an option:" 15 60 4 \
      1 "Start Cluster" \
      2 "Shutdown Cluster (VMs only)" \
      3 "Exit" \
      3>&1 1>&2 2>&3)
  else
    choice=$(whiptail --clear --backtitle "Proxmox Cluster Management" \
      --title "Main Menu" \
      --menu "Choose an option:" 15 60 4 \
      "1" "Start Cluster" \
      "2" "Shutdown Cluster (VMs only)" \
      "3" "Exit" \
      3>&1 1>&2 2>&3)
  fi
  
  echo $choice
}

function start_cluster() {
  clear
  
  log "1️⃣  Starting master node in Proxmox..."
  qm start 101
  sleep 60
  
  log "2️⃣  Checking master node readiness..."
  talosctl --nodes $MASTER_NODE --talosconfig ./talosconfig version || {
    error_log "Master not ready yet, wait longer..."
    read -p "Press Enter to continue..."
    return 1
  }
  
  log "3️⃣  Checking worker node 1 status..."
  if ! talosctl --nodes $WORKER_NODE_1 --talosconfig ./talosconfig version &> /dev/null; then
    log "   Starting worker node 1 (110)..."
    qm start 110
    sleep 20
  else
    log "   Worker node 1 is already running, skipping..."
  fi
  
  log "4️⃣  Checking worker node 2 status..."
  if ! talosctl --nodes $WORKER_NODE_2 --talosconfig ./talosconfig version &> /dev/null; then
    log "   Starting worker node 2 (112)..."
    qm start 112
    sleep 20
  else
    log "   Worker node 2 is already running, skipping..."
  fi
  
  log "5️⃣  Checking worker node 3 status..."
  if ! talosctl --nodes $WORKER_NODE_3 --talosconfig ./talosconfig version &> /dev/null; then
    log "   Starting worker node 3 (113)..."
    qm start 113
    sleep 20
  else
    log "   Worker node 3 is already running, skipping..."
  fi
  
  log "✅ Cluster startup sequence completed!"
  log "Checking nodes health..."
  kubectl get nodes
  
  # Check if all nodes are Ready
  if kubectl get nodes | grep -q "NotReady"; then
    error_log "⚠️  Some nodes are unhealthy!"
    log "Running health check script..."
    ./cluster_health_check.sh
  else
    log "✅ All nodes are healthy!"
  fi
  
  echo ""
  read -p "Press Enter to return to menu..."
}

function shutdown_cluster() {
  clear
  shutdown_log "Shutting down cluster (VMs only)..."
  
  # Check if worker node 1 is reachable before attempting shutdown
  shutdown_log "1️⃣  Checking worker node 1 connectivity..."
  if talosctl --nodes $WORKER_NODE_1 --talosconfig ./talosconfig version &> /dev/null; then
    shutdown_log "   Draining workloads from worker node 1..."
    talosctl shutdown --nodes $WORKER_NODE_1 --talosconfig ./talosconfig || {
      shutdown_log "Worker node 1 shutdown failed"
    }
  else
    shutdown_log "   Worker node 1 is already stopped or unreachable, skipping..."
  fi
  
  # Check if worker node 2 is reachable before attempting shutdown
  shutdown_log "2️⃣  Checking worker node 2 connectivity..."
  if talosctl --nodes $WORKER_NODE_2 --talosconfig ./talosconfig version &> /dev/null; then
    shutdown_log "   Draining workloads from worker node 2..."
    talosctl shutdown --nodes $WORKER_NODE_2 --talosconfig ./talosconfig || {
      shutdown_log "Worker node 2 shutdown failed"
    }
  else
    shutdown_log "   Worker node 2 is already stopped or unreachable, skipping..."
  fi
  
  # Check if worker node 3 is reachable before attempting shutdown
  shutdown_log "3️⃣  Checking worker node 3 connectivity..."
  if talosctl --nodes $WORKER_NODE_3 --talosconfig ./talosconfig version &> /dev/null; then
    shutdown_log "   Draining workloads from worker node 3..."
    talosctl shutdown --nodes $WORKER_NODE_3 --talosconfig ./talosconfig || {
      shutdown_log "Worker node 3 shutdown failed"
    }
  else
    shutdown_log "   Worker node 3 is already stopped or unreachable, skipping..."
  fi
  
  shutdown_log "4️⃣  Waiting 20 seconds to allow workers to stop gracefully..."
  sleep 20
  
  shutdown_log "5️⃣  Checking master node connectivity..."
  if talosctl --nodes $MASTER_NODE --talosconfig ./talosconfig version &> /dev/null; then
    shutdown_log "   Draining and shutting down the control-plane (master) node..."
    talosctl shutdown --nodes $MASTER_NODE --talosconfig ./talosconfig || {
      shutdown_log "Master node shutdown failed"
    }
    shutdown_log "✅ All Talos nodes are being safely shut down."
  else
    shutdown_log "   Master node is already stopped or unreachable, skipping..."
    shutdown_log "✅ Cluster is already shut down."
  fi
  
  shutdown_log "ℹ️  You can monitor shutdown status in Proxmox or using 'talosctl dmesg --nodes <ip>'."
  echo ""
  read -p "Press Enter to return to menu..."
}

# Main loop
while true; do
  choice=$(show_menu)
  exitstatus=$?
  
  if [ $exitstatus -ne 0 ]; then
    clear
    echo "Operation cancelled."
    exit 0
  fi
  
  case $choice in
    1)
      start_cluster
      ;;
    2)
      shutdown_cluster
      ;;
    3)
      clear
      echo "Goodbye!"
      exit 0
      ;;
    *)
      clear
      echo "Invalid option"
      exit 1
      ;;
  esac
done