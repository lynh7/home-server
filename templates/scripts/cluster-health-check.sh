#!/bin/bash

# Set stricter error handling
set -o pipefail

# Configuration
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-10.10.0.30}"
TALOSCONFIG="${TALOSCONFIG:-~/talosconfig}"
KUBECONFIG="${KUBECONFIG:-~/kubeconfig}"
MAX_RETRIES=3
RETRY_DELAY=10
AUTO_FIX="${AUTO_FIX:-true}"
TIMEOUT=30

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

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

log_success() {
    echo -e "${GREEN}[✓]${NC} $1"
}

# Talosctl wrapper
talosctl_exec() {
    talosctl -n "$CONTROL_PLANE_IP" "$@" 2>/dev/null
}

# Check Talos connectivity
check_talos_connectivity() {
    log_info "Checking Talos connectivity to $CONTROL_PLANE_IP..."
    
    if ! talosctl_exec version &>/dev/null; then
        log_error "Cannot connect to Talos at $CONTROL_PLANE_IP"
        return 1
    fi
    
    log_success "Talos is accessible"
    return 0
}

# List all services to find kube-apiserver
list_services() {
    log_debug "Available services on $CONTROL_PLANE_IP:"
    talosctl_exec service list 2>/dev/null || talosctl_exec get services 2>/dev/null || echo "Cannot list services"
}

# Check if kube-apiserver pod is running
check_kube_apiserver_pod() {
    log_info "Checking kube-apiserver pod status..."
    
    local status=$(talosctl_exec ps 2>/dev/null | grep -i "kube-apiserver" | head -1)
    
    if [ -z "$status" ]; then
        log_error "kube-apiserver pod not found"
        list_services
        return 1
    fi
    
    log_debug "kube-apiserver: $status"
    log_success "kube-apiserver pod is running"
    return 0
}

# Check if kube-apiserver is responding
check_api_server_responding() {
    log_info "Checking if API server is responding on port 6443..."
    
    if timeout 10 bash -c "curl -sk https://$CONTROL_PLANE_IP:6443/healthz 2>/dev/null | grep -q ok"; then
        log_success "API server is responding"
        return 0
    else
        log_error "API server is not responding on port 6443"
        log_debug "Trying alternative health check..."
        
        if timeout 10 bash -c "echo | openssl s_client -connect $CONTROL_PLANE_IP:6443 -quiet 2>/dev/null"; then
            log_warn "Port 6443 is open but health check failed"
            return 1
        else
            log_error "Cannot reach port 6443"
            return 1
        fi
    fi
}

# Restart kubelet and etcd (which manages apiserver in talos)
restart_control_plane_services() {
    log_fix "Restarting control plane services..."
    
    log_fix "1. Restarting kubelet..."
    talosctl_exec service kubelet restart 2>/dev/null || log_warn "Kubelet restart failed"
    
    sleep 10
    
    log_fix "2. Checking service status..."
    talosctl_exec service list 2>/dev/null | grep -E "kubelet|etcd|kube" || log_warn "Cannot get service status"
    
    log_info "Waiting 30 seconds for control plane to stabilize..."
    sleep 30
}

# Reboot node as last resort
reboot_control_plane() {
    log_fix "Rebooting control plane node $CONTROL_PLANE_IP..."
    
    talosctl_exec reboot 2>/dev/null || log_warn "Reboot command may have issues"
    
    log_info "Waiting 2 minutes for node to reboot..."
    sleep 120
    
    if talosctl_exec version &>/dev/null; then
        log_success "Node is back online"
        return 0
    else
        log_error "Node did not come back online"
        return 1
    fi
}

# Check kubectl connectivity
check_kubectl_connection() {
    log_info "Checking kubectl connectivity..."
    
    local kubeconfig="${KUBECONFIG/#\~/$HOME}"
    
    if ! timeout 10 kubectl --kubeconfig "$kubeconfig" cluster-info &>/dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        return 1
    fi
    
    log_success "kubectl is connected"
    return 0
}

# Wrapper for kubectl with timeout and kubeconfig
kubectl_exec() {
    local kubeconfig="${KUBECONFIG/#\~/$HOME}"
    timeout $TIMEOUT kubectl --kubeconfig "$kubeconfig" "$@" 2>/dev/null || {
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
    
    talosctl -n "$node_ip" service list 2>/dev/null | head -5 || log_warn "Cannot check services"
}

# Check node disk usage
check_node_disk_usage() {
    local node=$1
    local node_ip=$2
    
    log_debug "Checking disk usage on $node..."
    talosctl -n "$node_ip" df 2>/dev/null | tail -3 || log_warn "Cannot check disk"
}

# Check node logs
check_node_logs() {
    local node=$1
    local node_ip=$2
    
    log_debug "Last kubelet logs on $node:"
    talosctl -n "$node_ip" logs kubelet 2>/dev/null | tail -15 || log_warn "Cannot get kubelet logs"
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
    kubectl_exec get node "$node" -o jsonpath='{range .status.conditions[*]}{.type}{" = "}{.status}{" ("}{.reason}{"): "}{.message}{"\n"}{end}' 2>/dev/null || log_warn "Cannot get node conditions"
    
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
    
    # Step 2: Restart container runtime
    log_fix "Step 2: Restarting container runtime..."
    talosctl -n "$NODE_IP" service containerd stop 2>/dev/null || true
    sleep 5
    talosctl -n "$NODE_IP" service containerd start 2>/dev/null || log_warn "Failed to start containerd"
    sleep 10
    
    # Step 3: Restart kubelet
    log_fix "Step 3: Restarting kubelet..."
    talosctl -n "$NODE_IP" service kubelet restart 2>/dev/null || log_warn "Kubelet restart failed"
    sleep 15
    
    # Step 4: Verify recovery
    log_fix "Step 4: Verifying recovery..."
    READY=$(kubectl_exec get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    
    if [ "$READY" = "True" ]; then
        log_success "$node recovered!"
        return 0
    else
        log_warn "Node still not ready, attempting reboot..."
        talosctl -n "$NODE_IP" reboot 2>/dev/null || log_error "Reboot failed"
        return 1
    fi
}

# Force delete terminating pods globally
force_delete_all_terminating_pods() {
    log_fix "Cleaning up terminating pods cluster-wide..."
    
    TERMINATING=$(kubectl_exec get pods -A -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}') || return 0
    
    if [ -z "$TERMINATING" ]; then
        log_debug "No terminating pods found"
        return 0
    fi
    
    TERM_COUNT=$(echo "$TERMINATING" | wc -l)
    log_warn "Found $TERM_COUNT terminating pods, force deleting..."
    
    echo "$TERMINATING" | while IFS=$'\t' read -r ns pod; do
        if [ -n "$ns" ] && [ -n "$pod" ]; then
            kubectl_exec delete pod "$pod" -n "$ns" --grace-period=0 --force 2>/dev/null || true
        fi
    done
    
    sleep 3
}

# Fix scheduling disabled nodes
fix_scheduling_disabled() {
    log_info "Checking for scheduling disabled nodes..."
    
    DISABLED=$(kubectl_exec get nodes -o jsonpath='{range .items[?(@.spec.unschedulable==true)]}{.metadata.name}{"\n"}{end}') || return 0
    
    if [ -z "$DISABLED" ]; then
        log_debug "No scheduling disabled nodes"
        return 0
    fi
    
    log_warn "Found cordoned nodes:"
    echo "$DISABLED"
    
    if [ "$AUTO_FIX" = "true" ]; then
        echo "$DISABLED" | while read -r node; do
            if [ -n "$node" ]; then
                log_fix "Uncordoning $node..."
                kubectl_exec uncordon "$node" 2>/dev/null || true
            fi
        done
        sleep 5
    fi
}

# Check and fix node conditions
check_and_fix_node_conditions() {
    log_info "Checking node conditions..."
    
    NODES=$(kubectl_exec get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}') || {
        log_error "Cannot get nodes"
        return 1
    }
    
    if [ -z "$NODES" ]; then
        log_error "No nodes found in cluster"
        return 1
    fi
    
    while read -r NODE_NAME; do
        if [ -z "$NODE_NAME" ]; then
            continue
        fi
        
        READY=$(kubectl_exec get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') || continue
        READY_MSG=$(kubectl_exec get node "$NODE_NAME" -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}') || continue
        
        if [ "$READY" != "True" ]; then
            log_error "NotReady: $NODE_NAME - $READY_MSG"
            
            if [ "$AUTO_FIX" = "true" ]; then
                recover_notready_node "$NODE_NAME"
            fi
        else
            log_success "$NODE_NAME is Ready"
        fi
        
    done <<< "$NODES"
}

# Check and fix CNI
check_and_fix_cni() {
    log_info "Checking CNI plugin..."
    
    CNI_PODS=$(kubectl_exec get pods -A 2>/dev/null | grep -iE "calico|flannel|weave|cilium" || echo "") || return 0
    
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
        log_warn "CNI pods not running"
        
        if [ "$AUTO_FIX" = "true" ]; then
            log_fix "Restarting CNI daemonsets..."
            kubectl_exec get daemonsets -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}' 2>/dev/null | grep -iE "calico|flannel|weave|cilium" | while read -r ns ds; do
                if [ -n "$ds" ]; then
                    kubectl_exec rollout restart daemonset/"$ds" -n "$ns" 2>/dev/null || true
                fi
            done
            sleep 15
        fi
    else
        log_success "CNI is running"
    fi
}

# Check and fix kube-proxy
check_and_fix_kube_proxy() {
    log_info "Checking kube-proxy..."
    
    PROXY_COUNT=$(kubectl_exec get pods -n kube-system -l k8s-app=kube-proxy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l) || return 0
    
    if [ "$PROXY_COUNT" -eq 0 ]; then
        log_error "No kube-proxy pods found!"
        if [ "$AUTO_FIX" = "true" ]; then
            log_fix "Restarting kube-proxy..."
            kubectl_exec rollout restart daemonset/kube-proxy -n kube-system 2>/dev/null || log_warn "Failed"
            sleep 10
        fi
        return 1
    fi
    
    RUNNING=$(kubectl_exec get pods -n kube-system -l k8s-app=kube-proxy --field-selector=status.phase=Running -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | wc -l) || return 0
    
    if [ "$RUNNING" -lt "$PROXY_COUNT" ]; then
        log_warn "kube-proxy: $RUNNING/$PROXY_COUNT running"
        if [ "$AUTO_FIX" = "true" ]; then
            log_fix "Restarting kube-proxy..."
            kubectl_exec rollout restart daemonset/kube-proxy -n kube-system 2>/dev/null || log_warn "Failed"
            sleep 10
        fi
        return 1
    fi
    
    log_success "kube-proxy: $RUNNING/$PROXY_COUNT running"
}

# Clean up error pods
cleanup_error_pods() {
    log_info "Cleaning up error pods..."
    
    ERROR_PODS=$(kubectl_exec get pods -A -o jsonpath='{range .items[?(@.status.phase=="Failed" || @.status.phase=="Error")]}{.metadata.namespace}{"\t"}{.metadata.name}{"\n"}{end}') || return 0
    
    if [ -z "$ERROR_PODS" ]; then
        log_debug "No error pods found"
        return 0
    fi
    
    log_warn "Found error pods:"
    echo "$ERROR_PODS"
    
    if [ "$AUTO_FIX" = "true" ]; then
        echo "$ERROR_PODS" | while IFS=$'\t' read -r ns pod; do
            if [ -n "$ns" ] && [ -n "$pod" ]; then
                log_fix "Deleting $pod from $ns..."
                kubectl_exec delete pod "$pod" -n "$ns" --grace-period=0 --force 2>/dev/null || true
            fi
        done
        sleep 5
    fi
}

# Check cluster status
check_cluster_status() {
    log_info "Cluster status:"
    echo ""
    kubectl_exec get nodes 2>/dev/null || log_error "Cannot get nodes"
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
            log_success "All nodes are Ready!"
            return 0
        fi
        
        log_debug "Waiting... $NOT_READY nodes not ready ($elapsed/$max_wait sec)"
        sleep 10
        elapsed=$((elapsed + 10))
    done
    
    log_error "Timeout waiting for nodes"
    return 1
}

# Main function
main() {
    log_info "=========================================="
    log_info "Talos Kubernetes Health Check & Auto-Fix"
    log_info "=========================================="
    log_info "Auto-fix: $AUTO_FIX"
    log_info "TALOSCONFIG: $TALOSCONFIG"
    log_info "KUBECONFIG: $KUBECONFIG"
    log_info "Control Plane: $CONTROL_PLANE_IP"
    echo ""
    
    # Check Talos connectivity
    if ! check_talos_connectivity; then
        log_error "Cannot continue without Talos connectivity"
        return 1
    fi
    
    # Check kube-apiserver before kubectl
    if ! check_kube_apiserver_pod; then
        log_warn "kube-apiserver pod not found, attempting recovery..."
        if [ "$AUTO_FIX" = "true" ]; then
            restart_control_plane_services
            sleep 10
            
            if ! check_api_server_responding; then
                log_warn "Services restart failed, attempting node reboot..."
                if reboot_control_plane; then
                    log_info "Checking API server after reboot..."
                    sleep 10
                    if ! check_api_server_responding; then
                        log_error "API server still not responding after reboot"
                        return 1
                    fi
                else
                    return 1
                fi
            fi
        else
            return 1
        fi
    fi
    
    # Check kubectl connectivity
    if ! check_kubectl_connection; then
        log_error "Cannot continue without kubectl connectivity"
        return 1
    fi
    
    echo ""
    
    # Check initial status
    check_cluster_status
    
    # Fix scheduling blockers
    fix_scheduling_disabled
    
    # Force delete terminating pods
    force_delete_all_terminating_pods
    
    sleep 5
    
    # Check and fix nodes
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
        log_error "Recovery incomplete"
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
            fi
        done
    fi
    
    # Cleanup
    log_info "=========================================="
    cleanup_error_pods
    
    echo ""
    log_info "========== FINAL STATUS =========="
    check_cluster_status
    
    if [ "$RECOVERY_SUCCESS" = true ]; then
        log_success "All nodes are healthy!"
        return 0
    else
        log_error "Some nodes still not ready"
        return 1
    fi
}

# Run main
main "$@"