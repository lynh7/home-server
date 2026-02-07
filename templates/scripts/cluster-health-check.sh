#!/bin/bash

# Set stricter error handling
set -o pipefail

# Configuration
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-10.10.0.30}"
TALOSCONFIG="${TALOSCONFIG:-~/talosconfig}"
MAX_RETRIES=3
RETRY_DELAY=10
SCHEDULER_WAIT_TIME=30
AUTO_FIX="${AUTO_FIX:-true}"
TIMEOUT=30

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $1"
}

log_fix() {
    echo -e "${MAGENTA}[FIX]${NC} $1"
}

# Wrapper for kubectl with timeout
kubectl_exec() {
    timeout $TIMEOUT kubectl "$@" 2>/dev/null || {
        local exit_code=$?
        if [ $exit_code -eq 124 ]; then
            log_warn "kubectl command timed out: kubectl $*"
            return 1
        fi
        return $exit_code
    }
}

# Get node IP
get_node_ip() {
    local node=$1
    kubectl_exec get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null || echo ""
}

# Check node status via Talos
check_talos_node_status() {
    local node=$1
    local node_ip=$2
    
    log_debug "Checking Talos status on $node ($node_ip)..."
    
    # Check service statuses
    log_debug "  Checking services on $node..."
    talosctl -n "$node_ip" service containerd 2>/dev/null | head -5 || log_warn "Cannot check containerd status"
    talosctl -n "$node_ip" service kubelet 2>/dev/null | head -5 || log_warn "Cannot check kubelet status"
    talosctl -n "$node_ip" service apid 2>/dev/null | head -5 || log_warn "Cannot check apid status"
}

# Check node disk usage
check_node_disk_usage() {
    local node=$1
    local node_ip=$2
    
    log_debug "Checking disk usage on $node..."
    talosctl -n "$node_ip" df 2>/dev/null | tail -5 || log_warn "Cannot check disk usage"
}

# Check node logs
check_node_logs() {
    local node=$1
    local node_ip=$2
    
    log_debug "Last kubelet logs on $node:"
    talosctl -n "$node_ip" logs kubelet 2>/dev/null | tail -10 || log_warn "Cannot get kubelet logs"
    
    log_debug "Last containerd logs on $node:"
    talosctl -n "$node_ip" logs containerd 2>/dev/null | tail -10 || log_warn "Cannot get containerd logs"
}

# Deep debug NotReady node
debug_notready_node() {
    local node=$1
    
    log_error "========== DEBUGGING $node =========="
    
    NODE_IP=$(get_node_ip "$node")
    
    if [ -z "$NODE_IP" ]; then
        log_error "Cannot get IP for $node"
        return 1
    fi
    
    # Get node conditions
    log_debug "Node conditions:"
    kubectl_exec get node "$node" -o jsonpath='{range .status.conditions[*]}{.type}{" = "}{.status}{" ("}{.reason}{"): "}{.message}{"\n"}{end}' 2>/dev/null
    
    echo ""
    
    # Get node resource info
    log_debug "Node resources:"
    kubectl_exec get node "$node" -o jsonpath='{range .status.allocatable}{.}"; "{end}' 2>/dev/null
    echo ""
    echo ""
    
    # Check Talos services
    check_talos_node_status "$node" "$NODE_IP"
    echo ""
    
    # Check disk usage
    check_node_disk_usage "$node" "$NODE_IP"
    echo ""
    
    # Check logs
    check_node_logs "$node" "$NODE_IP"
    echo ""
}

# Drain node safely
drain_node() {
    local node=$1
    log_warn "Draining $node..."
    
    kubectl_exec drain "$node" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --grace-period=30 \
        --timeout=60s 2>/dev/null || log_warn "Drain had issues but continuing..."
    
    sleep 5
}

# Reboot node via Talos
reboot_node() {
    local node=$1
    local node_ip=$2
    
    log_fix "Rebooting $node via Talos..."
    
    talosctl -n "$node_ip" reboot 2>/dev/null || {
        log_warn "Reboot command failed, trying alternative..."
        talosctl -n "$node_ip" system shutdown --force 2>/dev/null || log_error "Failed to reboot $node"
    }
    
    sleep 60
    
    # Wait for node to come back
    log_info "Waiting for $node to come back online..."
    local max_wait=120
    local elapsed=0
    
    while [ $elapsed -lt $max_wait ]; do
        if talosctl -n "$node_ip" version 2>/dev/null; then
            log_info "✓ $node is back online"
            return 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    log_error "Node $node did not come back online"
    return 1
}

# Recover NotReady node
recover_notready_node() {
    local node=$1
    
    NODE_IP=$(get_node_ip "$node")
    
    if [ -z "$NODE_IP" ]; then
        log_error "Cannot get IP for $node"
        return 1
    fi
    
    READY_MSG=$(kubectl_exec get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)
    
    log_error "Recovering $node: $READY_MSG"
    
    if [ "$AUTO_FIX" != "true" ]; then
        return 1
    fi
    
    # Step 1: Force delete terminating pods
    log_fix "Step 1: Cleaning up terminating pods..."
    TERMINATING=$(kubectl_exec get pods -A -o jsonpath='{range .items[?(@.metadata.deletionTimestamp && @.spec.nodeName=="'$node'")]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}')
    
    if [ -n "$TERMINATING" ]; then
        echo "$TERMINATING" | while IFS=$'\t' read -r ns pod; do
            if [ -n "$ns" ] && [ -n "$pod" ]; then
                log_fix "  Deleting $pod from $ns..."
                kubectl_exec delete pod "$pod" -n "$ns" --grace-period=0 --force 2>/dev/null || true
            fi
        done
        sleep 5
    fi
    
    # Step 2: Check container runtime
    log_fix "Step 2: Checking and restarting container runtime..."
    
    log_fix "  Stopping containerd..."
    talosctl -n "$NODE_IP" service containerd stop 2>/dev/null || true
    sleep 5
    
    log_fix "  Starting containerd..."
    talosctl -n "$NODE_IP" service containerd start 2>/dev/null || {
        log_error "  Failed to start containerd, will reboot node"
        drain_node "$node"
        reboot_node "$node" "$NODE_IP"
        return $?
    }
    
    sleep 10
    
    # Step 3: Restart kubelet
    log_fix "Step 3: Restarting kubelet..."
    talosctl -n "$NODE_IP" service kubelet restart 2>/dev/null || log_warn "Kubelet restart failed"
    
    sleep 15
    
    # Step 4: Verify recovery
    log_fix "Step 4: Verifying recovery..."
    READY=$(kubectl_exec get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    
    if [ "$READY" = "True" ]; then
        log_info "✓ $node recovered!"
        return 0
    else
        log_warn "Node still not ready, attempting full reboot..."
        drain_node "$node"
        reboot_node "$node" "$NODE_IP"
        return $?
    fi
}

# Force delete terminating pods on a specific node
force_delete_terminating_pods() {
    local node=$1
    log_fix "Force deleting terminating pods on $node..."
    
    # Get terminating pods on this node
    TERMINATING=$(kubectl_exec get pods -A -o jsonpath='{range .items[?(@.metadata.deletionTimestamp && @.spec.nodeName=="'$node'")]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}')
    
    if [ -z "$TERMINATING" ]; then
        log_debug "No terminating pods found on $node"
        return 0
    fi
    
    log_error "Found $(echo "$TERMINATING" | wc -l) terminating pods on $node"
    
    echo "$TERMINATING" | while IFS=$'\t' read -r ns pod; do
        if [ -n "$ns" ] && [ -n "$pod" ]; then
            log_fix "Force deleting pod $pod in namespace $ns..."
            kubectl_exec delete pod "$pod" -n "$ns" --grace-period=0 --force
        fi
    done
    
    sleep 3
}

# Fix scheduling disabled nodes
fix_scheduling_disabled() {
    log_info "Checking for scheduling disabled nodes..."
    
    DISABLED=$(kubectl_exec get nodes -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{"\n"}{end}') || return 0
    
    if [ -z "$DISABLED" ]; then
        log_debug "No scheduling disabled nodes found"
        return 0
    fi
    
    log_error "Found scheduling disabled nodes:"
    echo "$DISABLED"
    
    if [ "$AUTO_FIX" = "true" ]; then
        echo "$DISABLED" | while read -r node; do
            if [ -n "$node" ]; then
                log_fix "Uncordoning $node..."
                kubectl_exec uncordon "$node"
            fi
        done
        sleep 5
    fi
}

# Force delete terminating system pods globally
force_delete_all_terminating_pods() {
    log_fix "Force deleting all terminating pods cluster-wide..."
    
    TERMINATING=$(kubectl_exec get pods -A -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}') || return 0
    
    if [ -z "$TERMINATING" ]; then
        log_debug "No terminating pods found"
        return 0
    fi
    
    TERM_COUNT=$(echo "$TERMINATING" | wc -l)
    log_error "Found $TERM_COUNT terminating pods, force deleting..."
    
    echo "$TERMINATING" | while IFS=$'\t' read -r ns pod; do
        if [ -n "$ns" ] && [ -n "$pod" ]; then
            kubectl_exec delete pod "$pod" -n "$ns" --grace-period=0 --force 2>/dev/null || true
        fi
    done
    
    sleep 3
}

# Check and fix node conditions
check_and_fix_node_conditions() {
    log_info "Checking node conditions..."
    
    NODES=$(kubectl_exec get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') || return 1
    
    if [ -z "$NODES" ]; then
        log_error "No nodes found"
        return 1
    fi
    
    NOT_READY_NODES=()
    
    while read -r NODE_NAME; do
        if [ -z "$NODE_NAME" ]; then
            continue
        fi
        
        log_debug "Checking $NODE_NAME..."
        
        READY=$(kubectl_exec get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') || continue
        READY_MSG=$(kubectl_exec get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}') || continue
        
        if [ "$READY" != "True" ]; then
            log_error "NotReady: $NODE_NAME - $READY_MSG"
            NOT_READY_NODES+=("$NODE_NAME")
            
            if [ "$AUTO_FIX" = "true" ]; then
                recover_notready_node "$NODE_NAME"
            fi
        else
            log_debug "✓ $NODE_NAME is Ready"
        fi
        
    done <<< "$NODES"
}

# Check and fix CNI
check_and_fix_cni() {
    log_info "Checking CNI plugin..."
    
    CNI_PODS=$(kubectl_exec get pods -A -o wide 2>/dev/null | grep -iE "calico|flannel|weave|cilium" || echo "") || return 0
    
    if [ -z "$CNI_PODS" ]; then
        log_error "No CNI pods found!"
        if [ "$AUTO_FIX" = "true" ]; then
            log_fix "Installing Flannel CNI..."
            kubectl_exec apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml 2>/dev/null || log_warn "Failed to install Flannel"
            sleep 20
        fi
        return 1
    fi
    
    NON_RUNNING=$(echo "$CNI_PODS" | grep -v "Running\|Succeeded" || echo "")
    if [ -n "$NON_RUNNING" ]; then
        log_error "CNI pods not running:"
        echo "$NON_RUNNING"
        
        if [ "$AUTO_FIX" = "true" ]; then
            force_delete_all_terminating_pods
            sleep 10
            
            log_fix "Restarting CNI daemonsets..."
            kubectl_exec get daemonsets -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' | grep -iE "calico|flannel|weave|cilium" | while read -r ns ds; do
                if [ -n "$ds" ]; then
                    kubectl_exec rollout restart daemonset/"$ds" -n "$ns" 2>/dev/null || true
                fi
            done
            sleep 15
        fi
    else
        log_info "✓ CNI is running"
    fi
}

# Check and fix kube-proxy
check_and_fix_kube_proxy() {
    log_info "Checking kube-proxy..."
    
    PROXY_COUNT=$(kubectl_exec get pods -n kube-system -l k8s-app=kube-proxy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | wc -l) || return 0
    
    if [ "$PROXY_COUNT" -eq 0 ]; then
        log_error "No kube-proxy pods found!"
        if [ "$AUTO_FIX" = "true" ]; then
            log_fix "Restarting kube-proxy..."
            kubectl_exec rollout restart daemonset/kube-proxy -n kube-system 2>/dev/null || log_warn "Failed"
            sleep 10
        fi
        return 1
    fi
    
    RUNNING=$(kubectl_exec get pods -n kube-system -l k8s-app=kube-proxy --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | wc -l) || return 0
    
    if [ "$RUNNING" -lt "$PROXY_COUNT" ]; then
        log_error "kube-proxy: $RUNNING/$PROXY_COUNT running"
        if [ "$AUTO_FIX" = "true" ]; then
            log_fix "Restarting kube-proxy..."
            kubectl_exec rollout restart daemonset/kube-proxy -n kube-system 2>/dev/null || log_warn "Failed"
            sleep 10
        fi
        return 1
    fi
    
    log_info "✓ kube-proxy: $RUNNING/$PROXY_COUNT running"
}

# Clean up pods in Error state
cleanup_error_pods() {
    log_info "Cleaning up pods in Error state..."
    
    ERROR_PODS=$(kubectl_exec get pods -A -o jsonpath='{range .items[?(@.status.phase=="Failed" || @.status.phase=="Error")]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}')
    
    if [ -z "$ERROR_PODS" ]; then
        log_debug "No error pods found"
        return 0
    fi
    
    log_error "Found error pods:"
    echo "$ERROR_PODS"
    
    if [ "$AUTO_FIX" = "true" ]; then
        echo "$ERROR_PODS" | while IFS=$'\t' read -r ns pod; do
            if [ -n "$ns" ] && [ -n "$pod" ]; then
                log_fix "Deleting error pod $pod from $ns..."
                kubectl_exec delete pod "$pod" -n "$ns" --grace-period=0 --force 2>/dev/null || true
            fi
        done
        sleep 5
    fi
}

# Check cluster status
check_cluster_status() {
    log_info "Current cluster status:"
    echo ""
    kubectl_exec get nodes 2>/dev/null || echo "Failed to get nodes"
    echo ""
}

# Wait for nodes to be ready
wait_for_nodes_ready() {
    log_info "Waiting for nodes to be Ready..."
    
    local max_wait=300
    local elapsed=0
    
    while [ $elapsed -lt $max_wait ]; do
        NOT_READY=$(kubectl_exec get nodes --no-headers 2>/dev/null | awk '$2 !~ /Ready/ {print $1}' | wc -l) || return 1
        
        if [ "$NOT_READY" -eq 0 ]; then
            log_info "✓ All nodes are Ready!"
            return 0
        fi
        
        log_debug "Waiting... $NOT_READY nodes not ready ($elapsed/$max_wait sec)"
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    log_error "Timeout waiting for nodes (still $NOT_READY not ready)"
    
    # List which nodes are not ready
    NOT_READY_LIST=$(kubectl_exec get nodes --no-headers 2>/dev/null | awk '$2 !~ /Ready/ {print $1}')
    log_error "NotReady nodes:"
    echo "$NOT_READY_LIST"
    
    return 1
}

# Main function
main() {
    log_info "=========================================="
    log_info "Talos Kubernetes Health Check & Auto-Fix"
    log_info "=========================================="
    log_info "Auto-fix: $AUTO_FIX"
    log_info "kubectl timeout: ${TIMEOUT}s"
    echo ""
    
    # Initial status
    check_cluster_status
    
    # Fix scheduling blockers
    fix_scheduling_disabled
    
    # Force delete all terminating pods first
    force_delete_all_terminating_pods
    
    sleep 5
    
    # Check and fix node conditions
    check_and_fix_node_conditions
    
    sleep 5
    
    # Check and fix CNI
    check_and_fix_cni
    
    sleep 5
    
    # Check and fix kube-proxy
    check_and_fix_kube_proxy
    
    sleep 5
    
    # Wait for recovery
    log_info "=========================================="
    if wait_for_nodes_ready; then
        RECOVERY_SUCCESS=true
    else
        RECOVERY_SUCCESS=false
        log_error "Recovery did not complete successfully"
    fi
    
    echo ""
    
    # Debug NotReady nodes
    NOT_READY_NODES=$(kubectl_exec get nodes --no-headers 2>/dev/null | awk '$2 !~ /Ready/ {print $1}')
    if [ -n "$NOT_READY_NODES" ]; then
        log_error "=========================================="
        log_error "DEBUGGING NOTREADY NODES"
        log_error "=========================================="
        echo "$NOT_READY_NODES" | while read -r node; do
            if [ -n "$node" ]; then
                debug_notready_node "$node"
                echo ""
                echo "=========================================="
                echo ""
            fi
        done
    fi
    
    # Cleanup error pods
    log_info "=========================================="
    cleanup_error_pods
    
    echo ""
    log_info "========== FINAL STATUS =========="
    check_cluster_status
    
    if [ "$RECOVERY_SUCCESS" = true ]; then
        log_info "✓ SUCCESS - All nodes are healthy!"
        return 0
    else
        log_error "⚠ INCOMPLETE - Some nodes still not ready (see debug output above)"
        return 1
    fi
}

# Run main
main "$@"