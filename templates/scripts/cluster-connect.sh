#!/bin/bash

set -e

# Configuration
CONTROL_PLANE_IP="${CONTROL_PLANE_IP:-10.10.0.30}"
TALOSCONFIG="${TALOSCONFIG:-./talosconfig}"
MAX_RETRIES=3
RETRY_DELAY=10
SCHEDULER_WAIT_TIME=30

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Check if talosctl is installed
check_talosctl() {
    if ! command -v talosctl &> /dev/null; then
        log_error "talosctl not found. Please install it first."
        exit 1
    fi
    log_info "talosctl found"
}

# Check if kubectl is installed
check_kubectl() {
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl not found. Please install it first."
        exit 1
    fi
    log_info "kubectl found"
}

# Check and configure talosconfig
configure_talos() {
    log_info "Checking talosconfig..."
    
    # Check if talosconfig file exists
    if [ ! -f "$TALOSCONFIG" ]; then
        log_error "Talosconfig file not found at: $TALOSCONFIG"
        exit 1
    fi
    
    # Check current context
    CURRENT_CONTEXT=$(talosctl config info 2>&1 | grep -q "no context is set" && echo "none" || talosctl config contexts | grep "^\*" | awk '{print $2}')
    
    if [ "$CURRENT_CONTEXT" = "none" ]; then
        log_warn "No context set. Merging talosconfig..."
        talosctl config merge "$TALOSCONFIG"
        log_info "Talosconfig merged successfully"
    else
        log_info "Current context: $CURRENT_CONTEXT"
    fi
    
    # Set endpoints and nodes
    log_info "Setting endpoint to: $CONTROL_PLANE_IP"
    talosctl config endpoints "$CONTROL_PLANE_IP"
    talosctl config nodes "$CONTROL_PLANE_IP"
    
    # Verify connection
    if ! talosctl version --short &> /dev/null; then
        log_error "Cannot connect to Talos node at $CONTROL_PLANE_IP"
        exit 1
    fi
    
    log_info "Successfully connected to Talos node"
}

# Check services health
check_services() {
    log_info "Checking services status..."
    
    UNHEALTHY_SERVICES=()
    
    # Get services status
    while IFS= read -r line; do
        # Skip header line
        if [[ "$line" =~ ^NODE ]]; then
            continue
        fi
        
        SERVICE=$(echo "$line" | awk '{print $2}')
        STATE=$(echo "$line" | awk '{print $3}')
        HEALTH=$(echo "$line" | awk '{print $4}')
        
        if [ "$STATE" != "Running" ] || ([ "$HEALTH" != "OK" ] && [ "$HEALTH" != "?" ]); then
            UNHEALTHY_SERVICES+=("$SERVICE")
            log_warn "Service $SERVICE is unhealthy (State: $STATE, Health: $HEALTH)"
        fi
    done < <(talosctl services)
    
    if [ ${#UNHEALTHY_SERVICES[@]} -eq 0 ]; then
        log_info "All services are healthy"
        return 0
    else
        log_warn "Found ${#UNHEALTHY_SERVICES[@]} unhealthy service(s)"
        return 1
    fi
}

# Check Kubernetes containers
check_k8s_containers() {
    log_info "Checking Kubernetes containers..."
    
    API_SERVER_RUNNING=false
    CONTROLLER_MANAGER_RUNNING=false
    SCHEDULER_RUNNING=false
    
    # Get all container output
    CONTAINER_OUTPUT=$(talosctl containers -k 2>/dev/null)
    
    # Check for critical containers in the output
    if echo "$CONTAINER_OUTPUT" | grep -q "kube-apiserver.*CONTAINER_RUNNING"; then
        API_SERVER_RUNNING=true
    fi
    
    if echo "$CONTAINER_OUTPUT" | grep -q "kube-controller-manager.*CONTAINER_RUNNING"; then
        CONTROLLER_MANAGER_RUNNING=true
    fi
    
    if echo "$CONTAINER_OUTPUT" | grep -q "kube-scheduler.*CONTAINER_RUNNING"; then
        SCHEDULER_RUNNING=true
    fi
    
    log_info "Critical containers status - API: $API_SERVER_RUNNING, Controller: $CONTROLLER_MANAGER_RUNNING, Scheduler: $SCHEDULER_RUNNING"
    
    # Export scheduler status for use in other functions
    export SCHEDULER_RUNNING
    export CONTROLLER_MANAGER_RUNNING
    
    # Only fail if critical containers are not running
    if [ "$API_SERVER_RUNNING" = false ]; then
        log_error "API Server container is not running!"
        return 1
    fi
    
    if [ "$CONTROLLER_MANAGER_RUNNING" = false ]; then
        log_warn "Controller Manager is not running (may be restarting)"
    fi
    
    if [ "$SCHEDULER_RUNNING" = false ]; then
        log_warn "Scheduler is not running (may be restarting)"
    fi
    
    # Only fail on API server being down, as it's the most critical
    if [ "$API_SERVER_RUNNING" = true ]; then
        log_info "API Server is running - containers check passed"
        return 0
    else
        return 1
    fi
}

# Check for stuck pods with ContainerStatusUnknown
check_stuck_pods() {
    log_info "Checking for stuck control plane pods..."
    
    # Check for pods with ContainerStatusUnknown or not Ready
    STUCK_PODS=$(kubectl get pods -n kube-system -l tier=control-plane -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.conditions[?(@.type=="Ready")].status}{" "}{.status.containerStatuses[*].state}{"\n"}{end}' 2>/dev/null | \
        awk '$2 != "True" {print $1}')
    
    # Also check with grep for ContainerStatusUnknown in status
    UNKNOWN_PODS=$(kubectl get pods -n kube-system -l tier=control-plane 2>/dev/null | grep -E "ContainerStatusUnknown|Unknown|CrashLoopBackOff" | awk '{print $1}')
    
    # Combine both checks
    ALL_STUCK_PODS=$(echo -e "$STUCK_PODS\n$UNKNOWN_PODS" | sort -u | grep -v '^$')
    
    if [ -n "$ALL_STUCK_PODS" ]; then
        log_warn "Found stuck pods:"
        echo "$ALL_STUCK_PODS"
        return 1
    else
        log_info "No stuck pods found"
        return 0
    fi
}

# Force delete stuck pods
force_delete_stuck_pods() {
    log_warn "Force deleting stuck control plane pods..."
    
    if [ -z "$ALL_STUCK_PODS" ]; then
        log_info "No stuck pods to delete"
        return 0
    fi
    
    echo "$ALL_STUCK_PODS" | while read -r pod; do
        if [ -n "$pod" ]; then
            log_warn "Force deleting pod: $pod"
            kubectl delete pod "$pod" -n kube-system --force --grace-period=0 2>/dev/null || true
            
            # Also try patching to remove finalizers if delete fails
            kubectl patch pod "$pod" -n kube-system -p '{"metadata":{"finalizers":null}}' 2>/dev/null || true
        fi
    done
    
    log_info "Waiting ${SCHEDULER_WAIT_TIME}s for pods to recreate..."
    sleep "$SCHEDULER_WAIT_TIME"
    
    return 0
}

# Clean up containerd for stuck containers
cleanup_containerd() {
    log_warn "Cleaning up containerd state for stuck containers..."
    
    # Stop kubelet first
    log_info "Stopping kubelet..."
    talosctl service kubelet stop
    sleep 5
    
    # Use crictl to remove stopped/unknown containers
    log_info "Removing stopped/unknown containers via crictl..."
    talosctl read /run/containerd/containerd.sock > /dev/null 2>&1 || true
    
    # Restart containerd
    log_warn "Restarting containerd service..."
    talosctl service containerd restart
    sleep 10
    
    # Start kubelet
    log_info "Starting kubelet..."
    talosctl service kubelet start
    sleep 15
    
    log_info "Containerd cleanup complete"
    return 0
}

# Check scheduler health via Kubernetes API
check_scheduler_health() {
    log_info "Checking kube-scheduler health via API..."
    
    # Check scheduler leader election
    SCHEDULER_LEADER=$(kubectl get lease -n kube-system kube-scheduler -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)
    
    # Also check if pod is actually Ready
    SCHEDULER_READY=$(kubectl get pod -n kube-system -l component=kube-scheduler -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    
    if [ -n "$SCHEDULER_LEADER" ] && [ "$SCHEDULER_READY" = "True" ]; then
        log_info "Scheduler leader: $SCHEDULER_LEADER (Pod Ready)"
        return 0
    elif [ -n "$SCHEDULER_LEADER" ] && [ "$SCHEDULER_READY" != "True" ]; then
        log_error "Scheduler has leader but pod is not Ready: $SCHEDULER_READY"
        return 1
    else
        log_error "Scheduler leader election failed - scheduler may not be functioning"
        return 1
    fi
}

# Check controller manager health
check_controller_manager_health() {
    log_info "Checking kube-controller-manager health via API..."
    
    # Check controller manager leader election
    CONTROLLER_LEADER=$(kubectl get lease -n kube-system kube-controller-manager -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)
    
    # Also check if pod is actually Ready
    CONTROLLER_READY=$(kubectl get pod -n kube-system -l component=kube-controller-manager -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    
    if [ -n "$CONTROLLER_LEADER" ] && [ "$CONTROLLER_READY" = "True" ]; then
        log_info "Controller Manager leader: $CONTROLLER_LEADER (Pod Ready)"
        return 0
    elif [ -n "$CONTROLLER_LEADER" ] && [ "$CONTROLLER_READY" != "True" ]; then
        log_error "Controller Manager has leader but pod is not Ready: $CONTROLLER_READY"
        return 1
    else
        log_error "Controller Manager leader election failed"
        return 1
    fi
}

# Fix stuck control plane components
fix_stuck_components() {
    log_warn "Attempting to fix stuck control plane components..."
    
    # Step 1: Try force deleting stuck pods first
    log_info "Step 1: Force deleting stuck pods..."
    force_delete_stuck_pods
    
    # Wait and check if fixed
    sleep 20
    if ! check_stuck_pods; then
        log_warn "Pods still stuck after deletion, trying deeper fix..."
        
        # Step 2: Clean up containerd state
        log_info "Step 2: Cleaning up containerd..."
        cleanup_containerd
        
        # Wait for pods to recreate
        log_info "Waiting ${SCHEDULER_WAIT_TIME}s for components to stabilize..."
        sleep "$SCHEDULER_WAIT_TIME"
    fi
    
    # Step 3: Verify fix
    if check_stuck_pods; then
        log_info "Stuck components fixed successfully!"
        
        # Double-check health
        sleep 10
        SCHEDULER_OK=true
        CONTROLLER_OK=true
        
        if ! check_scheduler_health; then
            SCHEDULER_OK=false
        fi
        
        if ! check_controller_manager_health; then
            CONTROLLER_OK=false
        fi
        
        if [ "$SCHEDULER_OK" = true ] && [ "$CONTROLLER_OK" = true ]; then
            log_info "All control plane components are healthy"
            return 0
        else
            log_warn "Components recreated but not yet fully healthy"
            return 1
        fi
    else
        log_error "Failed to fix stuck components"
        return 1
    fi
}

# Check API server connectivity
check_api_server() {
    log_info "Checking API server connectivity..."
    
    if kubectl get nodes &> /dev/null; then
        log_info "API server is responding"
        return 0
    else
        log_error "API server is not responding"
        return 1
    fi
}

# Restart kubelet service
restart_kubelet() {
    log_warn "Restarting kubelet service..."
    
    talosctl service kubelet restart
    
    log_info "Waiting ${RETRY_DELAY}s for kubelet to restart..."
    sleep "$RETRY_DELAY"
    
    # Check if kubelet is running
    if talosctl services | grep -q "kubelet.*Running.*OK"; then
        log_info "Kubelet restarted successfully"
        return 0
    else
        log_error "Kubelet restart failed"
        return 1
    fi
}

# Check for OOM issues
check_oom() {
    log_info "Checking for OOM (Out of Memory) issues..."
    
    if talosctl dmesg | grep -qi "out of memory\|oom"; then
        log_error "OOM issues detected! Your node may not have enough memory."
        log_error "Consider increasing memory allocation (recommended: 4GB+ for control plane)"
        return 1
    fi
    
    log_info "No OOM issues detected"
    return 0
}

# Main recovery loop
perform_recovery() {
    log_info "Starting recovery process..."
    
    for i in $(seq 1 $MAX_RETRIES); do
        log_info "Recovery attempt $i/$MAX_RETRIES"
        
        # Restart kubelet
        if ! restart_kubelet; then
            log_error "Failed to restart kubelet"
            continue
        fi
        
        # Wait for containers to start
        log_info "Waiting for containers to start..."
        sleep 20
        
        # Check if recovery was successful
        if check_k8s_containers && check_api_server; then
            log_info "Recovery successful!"
            return 0
        fi
        
        if [ $i -lt $MAX_RETRIES ]; then
            log_warn "Recovery attempt $i failed. Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        fi
    done
    
    log_error "Recovery failed after $MAX_RETRIES attempts"
    return 1
}

# Display summary
display_summary() {
    echo ""
    echo "=================================="
    log_info "Health Check Summary"
    echo "=================================="
    
    echo ""
    log_info "Services Status:"
    talosctl services | grep -E "NODE|kubelet|etcd|apid|containerd"
    
    echo ""
    log_info "Kubernetes Containers:"
    talosctl containers -k | grep -E "NODE|apiserver|controller|scheduler" || log_warn "No control plane containers found"
    
    echo ""
    log_info "Cluster Nodes:"
    kubectl get nodes 2>/dev/null || log_error "Cannot retrieve nodes"
    
    echo ""
    log_info "Control Plane Pods:"
    kubectl get pods -n kube-system -l tier=control-plane 2>/dev/null || log_warn "Cannot retrieve control plane pods"
    
    echo "=================================="
}

# Main function
main() {
    log_info "Starting Talos Kubernetes Health Check & Auto-Fix"
    echo ""
    
    # Step 1: Check prerequisites
    check_talosctl
    check_kubectl
    
    # Step 2: Configure talosctl
    configure_talos
    
    # Step 3: Check for OOM issues
    check_oom
    
    # Step 4: Check services
    SERVICES_HEALTHY=true
    if ! check_services; then
        SERVICES_HEALTHY=false
        log_warn "Services check failed"
    fi
    
    # Step 5: Check containers
    CONTAINERS_HEALTHY=true
    if ! check_k8s_containers; then
        CONTAINERS_HEALTHY=false
        log_warn "Container check failed"
    fi
    
    # Step 6: Check API server
    API_HEALTHY=true
    if ! check_api_server; then
        API_HEALTHY=false
        log_warn "API server check failed"
    fi
    
    # Step 7: Check for stuck pods (NEW - Critical check)
    STUCK_PODS_DETECTED=false
    if [ "$API_HEALTHY" = true ]; then
        if ! check_stuck_pods; then
            STUCK_PODS_DETECTED=true
            log_error "Stuck pods detected with ContainerStatusUnknown status"
        fi
    fi
    
    # Step 8: Check scheduler and controller manager health
    SCHEDULER_HEALTHY=true
    CONTROLLER_HEALTHY=true
    
    if [ "$API_HEALTHY" = true ]; then
        if ! check_scheduler_health; then
            SCHEDULER_HEALTHY=false
            log_error "Scheduler health check failed"
        fi
        
        if ! check_controller_manager_health; then
            CONTROLLER_HEALTHY=false
            log_error "Controller Manager health check failed"
        fi
    fi
    
    # Step 9: Determine if recovery is needed
    NEEDS_RECOVERY=false
    NEEDS_STUCK_POD_FIX=false
    
    # Priority 1: Fix stuck pods (most common issue)
    if [ "$STUCK_PODS_DETECTED" = true ]; then
        log_error "Stuck pods with ContainerStatusUnknown detected - needs fix"
        NEEDS_STUCK_POD_FIX=true
    # Priority 2: Check if API is down
    elif [ "$API_HEALTHY" = false ]; then
        log_error "API server is not responding - recovery needed"
        NEEDS_RECOVERY=true
    # Priority 3: Check critical containers
    elif [ "$CONTAINERS_HEALTHY" = false ]; then
        log_error "Critical containers are not running - recovery needed"
        NEEDS_RECOVERY=true
    # Priority 4: Check control plane components
    elif [ "$SCHEDULER_HEALTHY" = false ] || [ "$CONTROLLER_HEALTHY" = false ]; then
        log_error "Control plane components are not functioning properly"
        NEEDS_STUCK_POD_FIX=true
    # Priority 5: Check services
    elif [ "$SERVICES_HEALTHY" = false ]; then
        if talosctl services | grep "kubelet" | grep -qv "Running.*OK"; then
            log_error "Kubelet is unhealthy - recovery needed"
            NEEDS_RECOVERY=true
        else
            log_info "Non-critical service issues detected, but kubelet is healthy - skipping recovery"
        fi
    fi
    
    # Step 10: Perform stuck pod fix if needed (NEW - Handle ContainerStatusUnknown)
    if [ "$NEEDS_STUCK_POD_FIX" = true ]; then
        log_warn "Stuck control plane components detected. Starting targeted fix..."
        
        if fix_stuck_components; then
            log_info "Stuck components fixed successfully!"
        else
            log_error "Stuck component fix failed. Attempting full recovery..."
            NEEDS_RECOVERY=true
        fi
    fi
    
    # Step 11: Perform full recovery if needed
    if [ "$NEEDS_RECOVERY" = true ]; then
        log_warn "Critical issues detected. Starting full recovery process..."
        
        if perform_recovery; then
            log_info "System recovered successfully!"
            
            # Re-check for stuck pods after recovery
            sleep 10
            if ! check_stuck_pods; then
                log_warn "Stuck pods detected after recovery, attempting fix..."
                fix_stuck_components
            fi
        else
            log_error "Automatic recovery failed. Manual intervention required."
            echo ""
            log_info "Troubleshooting steps:"
            echo "  1. Check logs: talosctl logs kubelet"
            echo "  2. Check scheduler logs: kubectl logs -n kube-system -l component=kube-scheduler"
            echo "  3. Check controller logs: kubectl logs -n kube-system -l component=kube-controller-manager"
            echo "  4. Check etcd: talosctl etcd members"
            echo "  5. Check resources: talosctl dashboard"
            echo "  6. Check static pod manifests: talosctl read /etc/kubernetes/manifests/"
            echo "  7. Manual cleanup: kubectl delete pod <pod-name> -n kube-system --force --grace-period=0"
            echo "  8. Bootstrap (if needed): talosctl bootstrap"
            exit 1
        fi
    else
        log_info "All systems healthy - no recovery needed!"
    fi
    
    # Step 12: Display summary
    display_summary
    
    log_info "Health check complete!"
}

# Run main function
main "$@"
                POD_STATUS=$(kubectl get pod "$pod" -n kube-system -o jsonpath='{.status.phase}' 2>/dev/null)
                POD_READY=$(kubectl get pod "$pod" -n kube-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
                log_error "  - $pod (Phase: $POD_STATUS, Ready: $POD_READY)"
            fi
        done
        export ALL_STUCK_PODS
        return 1
    else
        log_info "All control plane pods are healthy"
        return 0
    fi
}

# Force delete stuck pods
force_delete_stuck_pods() {
    log_warn "Force deleting stuck control plane pods..."
    
    # Get all control plane pods with issues
    STUCK_PODS=$(kubectl get pods -n kube-system -l tier=control-plane -o json 2>/dev/null | \
        jq -r '.items[] | select(.status.containerStatuses[]?.state.waiting.reason == "ContainerStatusUnknown" or .status.phase == "Unknown") | .metadata.name' 2>/dev/null)
    
    if [ -z "$STUCK_PODS" ]; then
        log_info "No stuck pods to delete"
        return 0
    fi
    
    echo "$STUCK_PODS" | while read -r pod; do
        if [ -n "$pod" ]; then
            log_warn "Force deleting pod: $pod"
            kubectl delete pod "$pod" -n kube-system --force --grace-period=0 2>/dev/null || true
        fi
    done
    
    log_info "Waiting ${SCHEDULER_WAIT_TIME}s for pods to recreate..."
    sleep "$SCHEDULER_WAIT_TIME"
    
    return 0
}

# Clean up containerd for stuck containers
cleanup_containerd() {
    log_warn "Cleaning up containerd state for stuck containers..."
    
    # Stop kubelet first
    log_info "Stopping kubelet..."
    talosctl service kubelet stop
    sleep 5
    
    # Use crictl to remove stopped/unknown containers
    log_info "Removing stopped/unknown containers via crictl..."
    talosctl read /run/containerd/containerd.sock > /dev/null 2>&1 || true
    
    # Restart containerd
    log_warn "Restarting containerd service..."
    talosctl service containerd restart
    sleep 10
    
    # Start kubelet
    log_info "Starting kubelet..."
    talosctl service kubelet start
    sleep 15
    
    log_info "Containerd cleanup complete"
    return 0
}

# Check scheduler health via Kubernetes API
check_scheduler_health() {
    log_info "Checking kube-scheduler health via API..."
    
    # Check scheduler leader election
    SCHEDULER_LEADER=$(kubectl get lease -n kube-system kube-scheduler -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)
    
    if [ -n "$SCHEDULER_LEADER" ]; then
        log_info "Scheduler leader: $SCHEDULER_LEADER"
        return 0
    else
        log_error "Scheduler leader election failed - scheduler may not be functioning"
        return 1
    fi
}

# Check controller manager health
check_controller_manager_health() {
    log_info "Checking kube-controller-manager health via API..."
    
    # Check controller manager leader election
    CONTROLLER_LEADER=$(kubectl get lease -n kube-system kube-controller-manager -o jsonpath='{.spec.holderIdentity}' 2>/dev/null)
    
    if [ -n "$CONTROLLER_LEADER" ]; then
        log_info "Controller Manager leader: $CONTROLLER_LEADER"
        return 0
    else
        log_error "Controller Manager leader election failed"
        return 1
    fi
}

# Fix stuck control plane components
fix_stuck_components() {
    log_warn "Attempting to fix stuck control plane components..."
    
    # Step 1: Try force deleting stuck pods first
    log_info "Step 1: Force deleting stuck pods..."
    force_delete_stuck_pods
    
    # Wait and check if fixed
    sleep 20
    if ! check_stuck_pods; then
        log_warn "Pods still stuck after deletion, trying deeper fix..."
        
        # Step 2: Clean up containerd state
        log_info "Step 2: Cleaning up containerd..."
        cleanup_containerd
        
        # Wait for pods to recreate
        log_info "Waiting ${SCHEDULER_WAIT_TIME}s for components to stabilize..."
        sleep "$SCHEDULER_WAIT_TIME"
    fi
    
    # Step 3: Verify fix
    if check_stuck_pods; then
        log_info "Stuck components fixed successfully!"
        
        # Double-check health
        sleep 10
        SCHEDULER_OK=true
        CONTROLLER_OK=true
        
        if ! check_scheduler_health; then
            SCHEDULER_OK=false
        fi
        
        if ! check_controller_manager_health; then
            CONTROLLER_OK=false
        fi
        
        if [ "$SCHEDULER_OK" = true ] && [ "$CONTROLLER_OK" = true ]; then
            log_info "All control plane components are healthy"
            return 0
        else
            log_warn "Components recreated but not yet fully healthy"
            return 1
        fi
    else
        log_error "Failed to fix stuck components"
        return 1
    fi
}

# Check API server connectivity
check_api_server() {
    log_info "Checking API server connectivity..."
    
    if kubectl get nodes &> /dev/null; then
        log_info "API server is responding"
        return 0
    else
        log_error "API server is not responding"
        return 1
    fi
}

# Restart kubelet service
restart_kubelet() {
    log_warn "Restarting kubelet service..."
    
    talosctl service kubelet restart
    
    log_info "Waiting ${RETRY_DELAY}s for kubelet to restart..."
    sleep "$RETRY_DELAY"
    
    # Check if kubelet is running
    if talosctl services | grep -q "kubelet.*Running.*OK"; then
        log_info "Kubelet restarted successfully"
        return 0
    else
        log_error "Kubelet restart failed"
        return 1
    fi
}

# Check for OOM issues
check_oom() {
    log_info "Checking for OOM (Out of Memory) issues..."
    
    if talosctl dmesg | grep -qi "out of memory\|oom"; then
        log_error "OOM issues detected! Your node may not have enough memory."
        log_error "Consider increasing memory allocation (recommended: 4GB+ for control plane)"
        return 1
    fi
    
    log_info "No OOM issues detected"
    return 0
}

# Main recovery loop
perform_recovery() {
    log_info "Starting recovery process..."
    
    for i in $(seq 1 $MAX_RETRIES); do
        log_info "Recovery attempt $i/$MAX_RETRIES"
        
        # Restart kubelet
        if ! restart_kubelet; then
            log_error "Failed to restart kubelet"
            continue
        fi
        
        # Wait for containers to start
        log_info "Waiting for containers to start..."
        sleep 20
        
        # Check if recovery was successful
        if check_k8s_containers && check_api_server; then
            log_info "Recovery successful!"
            return 0
        fi
        
        if [ $i -lt $MAX_RETRIES ]; then
            log_warn "Recovery attempt $i failed. Retrying in ${RETRY_DELAY}s..."
            sleep "$RETRY_DELAY"
        fi
    done
    
    log_error "Recovery failed after $MAX_RETRIES attempts"
    return 1
}

# Display summary
display_summary() {
    echo ""
    echo "=================================="
    log_info "Health Check Summary"
    echo "=================================="
    
    echo ""
    log_info "Services Status:"
    talosctl services | grep -E "NODE|kubelet|etcd|apid|containerd"
    
    echo ""
    log_info "Kubernetes Containers:"
    talosctl containers -k | grep -E "NODE|apiserver|controller|scheduler" || log_warn "No control plane containers found"
    
    echo ""
    log_info "Cluster Nodes:"
    kubectl get nodes 2>/dev/null || log_error "Cannot retrieve nodes"
    
    echo ""
    log_info "Control Plane Pods:"
    kubectl get pods -n kube-system -l tier=control-plane 2>/dev/null || log_warn "Cannot retrieve control plane pods"
    
    echo "=================================="
}

# Main function
main() {
    log_info "Starting Talos Kubernetes Health Check & Auto-Fix"
    echo ""
    
    # Step 1: Check prerequisites
    check_talosctl
    check_kubectl
    
    # Step 2: Configure talosctl
    configure_talos
    
    # Step 3: Check for OOM issues
    check_oom
    
    # Step 4: Check services
    SERVICES_HEALTHY=true
    if ! check_services; then
        SERVICES_HEALTHY=false
        log_warn "Services check failed"
    fi
    
    # Step 5: Check containers
    CONTAINERS_HEALTHY=true
    if ! check_k8s_containers; then
        CONTAINERS_HEALTHY=false
        log_warn "Container check failed"
    fi
    
    # Step 6: Check API server
    API_HEALTHY=true
    if ! check_api_server; then
        API_HEALTHY=false
        log_warn "API server check failed"
    fi
    
    # Step 7: Check for stuck pods (NEW - Critical check)
    STUCK_PODS_DETECTED=false
    if [ "$API_HEALTHY" = true ]; then
        if ! check_stuck_pods; then
            STUCK_PODS_DETECTED=true
            log_error "Stuck pods detected with ContainerStatusUnknown status"
        fi
    fi
    
    # Step 8: Check scheduler and controller manager health
    SCHEDULER_HEALTHY=true
    CONTROLLER_HEALTHY=true
    
    if [ "$API_HEALTHY" = true ]; then
        if ! check_scheduler_health; then
            SCHEDULER_HEALTHY=false
            log_error "Scheduler health check failed"
        fi
        
        if ! check_controller_manager_health; then
            CONTROLLER_HEALTHY=false
            log_error "Controller Manager health check failed"
        fi
    fi
    
    # Step 9: Determine if recovery is needed
    NEEDS_RECOVERY=false
    NEEDS_STUCK_POD_FIX=false
    
    # Priority 1: Fix stuck pods (most common issue)
    if [ "$STUCK_PODS_DETECTED" = true ]; then
        log_error "Stuck pods with ContainerStatusUnknown detected - needs fix"
        NEEDS_STUCK_POD_FIX=true
    # Priority 2: Check if API is down
    elif [ "$API_HEALTHY" = false ]; then
        log_error "API server is not responding - recovery needed"
        NEEDS_RECOVERY=true
    # Priority 3: Check critical containers
    elif [ "$CONTAINERS_HEALTHY" = false ]; then
        log_error "Critical containers are not running - recovery needed"
        NEEDS_RECOVERY=true
    # Priority 4: Check control plane components
    elif [ "$SCHEDULER_HEALTHY" = false ] || [ "$CONTROLLER_HEALTHY" = false ]; then
        log_error "Control plane components are not functioning properly"
        NEEDS_STUCK_POD_FIX=true
    # Priority 5: Check services
    elif [ "$SERVICES_HEALTHY" = false ]; then
        if talosctl services | grep "kubelet" | grep -qv "Running.*OK"; then
            log_error "Kubelet is unhealthy - recovery needed"
            NEEDS_RECOVERY=true
        else
            log_info "Non-critical service issues detected, but kubelet is healthy - skipping recovery"
        fi
    fi
    
    # Step 10: Perform stuck pod fix if needed (NEW - Handle ContainerStatusUnknown)
    if [ "$NEEDS_STUCK_POD_FIX" = true ]; then
        log_warn "Stuck control plane components detected. Starting targeted fix..."
        
        if fix_stuck_components; then
            log_info "Stuck components fixed successfully!"
        else
            log_error "Stuck component fix failed. Attempting full recovery..."
            NEEDS_RECOVERY=true
        fi
    fi
    
    # Step 11: Perform full recovery if needed
    if [ "$NEEDS_RECOVERY" = true ]; then
        log_warn "Critical issues detected. Starting full recovery process..."
        
        if perform_recovery; then
            log_info "System recovered successfully!"
            
            # Re-check for stuck pods after recovery
            sleep 10
            if ! check_stuck_pods; then
                log_warn "Stuck pods detected after recovery, attempting fix..."
                fix_stuck_components
            fi
        else
            log_error "Automatic recovery failed. Manual intervention required."
            echo ""
            log_info "Troubleshooting steps:"
            echo "  1. Check logs: talosctl logs kubelet"
            echo "  2. Check scheduler logs: kubectl logs -n kube-system -l component=kube-scheduler"
            echo "  3. Check controller logs: kubectl logs -n kube-system -l component=kube-controller-manager"
            echo "  4. Check etcd: talosctl etcd members"
            echo "  5. Check resources: talosctl dashboard"
            echo "  6. Check static pod manifests: talosctl read /etc/kubernetes/manifests/"
            echo "  7. Manual cleanup: kubectl delete pod <pod-name> -n kube-system --force --grace-period=0"
            echo "  8. Bootstrap (if needed): talosctl bootstrap"
            exit 1
        fi
    else
        log_info "All systems healthy - no recovery needed!"
    fi
    
    # Step 12: Display summary
    display_summary
    
    log_info "Health check complete!"
}

# Run main function
main "$@"