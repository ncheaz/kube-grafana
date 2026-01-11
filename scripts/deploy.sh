#!/bin/bash

# =============================================================================
# GRAFANA DEPLOYMENT SCRIPT
# =============================================================================
# This script deploys Grafana using the official Grafana Helm chart with optional features:
# - Database integration with local PostgreSQL
# - Ingress configuration
# - Comprehensive verification
# - MicroK8s support via Multipass

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# MicroK8s configuration
USE_MICROK8S=true
MICROK8S_VM="microk8s"

# Source utility functions
source "$SCRIPT_DIR/utils.sh"

# =============================================================================
# MICROK8S WRAPPER FUNCTIONS
# =============================================================================

# Function to execute kubectl commands (with MicroK8s support)
kubectl_cmd() {
    if [[ "$USE_MICROK8S" == "true" ]]; then
        multipass exec "$MICROK8S_VM" -- microk8s kubectl "$@"
    else
        kubectl "$@"
    fi
}

# Function to execute helm commands (with MicroK8s support)
helm_cmd() {
    if [[ "$USE_MICROK8S" == "true" ]]; then
        multipass exec "$MICROK8S_VM" -- microk8s helm "$@"
    else
        helm "$@"
    fi
}

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================

# Deployment configuration
DEPLOYMENT_LOG="$PROJECT_ROOT/deployment.log"
BACKUP_DIR="$PROJECT_ROOT/backups"
TEMP_DIR="$PROJECT_ROOT/temp"

# Chart configuration - Official Grafana chart only
HELM_RELEASE_NAME="grafana"
NAMESPACE="${GRAFANA_NAMESPACE:-grafana}"
GRAFANA_REPO_NAME="grafana"
GRAFANA_REPO_URL="https://grafana.github.io/helm-charts"
GRAFANA_CHART_NAME="grafana"

# Feature flags
# ENABLE_DB_FIX="${ENABLE_DB_FIX:-true}"  # DB fix disabled - not needed
ENABLE_INGRESS="${ENABLE_INGRESS:-true}"

# Ingress configuration
# For MicroK8s, use "public" ingress class by default
if [[ "$USE_MICROK8S" == "true" ]]; then
    INGRESS_CLASS="${INGRESS_CLASS:-public}"
else
    INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
fi
INGRESS_HOST="${INGRESS_HOST:-grafana.local}"
INGRESS_PATH="${INGRESS_PATH:-/}"
INGRESS_PATH_TYPE="${INGRESS_PATH_TYPE:-Prefix}"

# Database configuration
DB_HOST="${DB_HOST:-postgres-postgresql.postgres.svc.cluster.local}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-grafana}"
DB_USER="${DB_USER:-grafana}"
DB_PASSWORD="${DB_PASSWORD:-grafana_password123}"
POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-changeme123}"

# =============================================================================
# WRAPPER FUNCTIONS FOR CONSOLIDATED UTILITIES
# =============================================================================

# Function to setup database permissions (wrapper for utils function)
# setup_database_permissions() {
#     if [[ "$ENABLE_DB_FIX" != "true" ]]; then
#         log "INFO" "Database fix disabled, skipping database setup"
#         return 0
#     fi
#
#     # Skip database setup for MicroK8s as PostgreSQL is already configured
#     log "INFO" "Using existing PostgreSQL database configuration"
# }

# Function to test database connectivity (wrapper for utils function)
# test_database_connectivity() {
#     if [[ "$ENABLE_DB_FIX" != "true" ]]; then
#         log "INFO" "Database fix disabled, skipping connectivity test"
#         return 0
#     fi
#
#     # Test database connectivity from the cluster
#     log "INFO" "Testing database connectivity from cluster"
#     if kubectl_cmd exec -n postgres postgres-postgresql-0 -- bash -c "PGPASSWORD=$DB_PASSWORD psql -U $DB_USER -d $DB_NAME -h $DB_HOST -p $DB_PORT -c 'SELECT 1;'" &>/dev/null; then
#         log "SUCCESS" "Database connectivity test passed"
#         return 0
#     else
#         log "WARN" "Database connectivity test failed, but deployment may still work"
#         return 0
#     fi
# }

# Function to check ingress controller (wrapper for utils function)
check_ingress_controller() {
    if [[ "$ENABLE_INGRESS" != "true" ]]; then
        log "INFO" "Ingress disabled, skipping ingress controller check"
        return 0
    fi
    
    log "STEP" "Checking Ingress Controller availability"
    
    # Check for nginx ingress controller in MicroK8s
    if kubectl_cmd get pods -n ingress -l app.kubernetes.io/name=ingress-nginx &>/dev/null; then
        local ingress_pods=$(kubectl_cmd get pods -n ingress -l app.kubernetes.io/name=ingress-nginx --no-headers | wc -l)
        if [[ $ingress_pods -gt 0 ]]; then
            log "SUCCESS" "NGINX Ingress Controller found with $ingress_pods pods"
            return 0
        fi
    fi
    
    # Check for ingress classes
    local ingress_classes=$(kubectl_cmd get ingressclass --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
    if [[ -n "$ingress_classes" ]]; then
        log "INFO" "Available Ingress Classes: $ingress_classes"
        
        # Check if requested ingress class exists
        if echo "$ingress_classes" | grep -q "$INGRESS_CLASS"; then
            log "SUCCESS" "Ingress class '$INGRESS_CLASS' is available"
            return 0
        else
            log "WARN" "Ingress class '$INGRESS_CLASS' not found. Available: $ingress_classes"
            return 1
        fi
    else
        log "WARN" "No Ingress Controller found. Ingress may not work properly."
        return 1
    fi
}

# Function to setup local hosts entry (wrapper for utils function)
setup_hosts_entry() {
    if [[ "$ENABLE_INGRESS" != "true" ]]; then
        return 0
    fi
    
    local node_ip="${NODE_IP:-10.110.40.193}"
    local ingress_host="$INGRESS_HOST"
    
    # Check if the entry already exists in /etc/hosts
    if grep -q "^[[:space:]]*$node_ip[[:space:]]\+$ingress_host" /etc/hosts 2>/dev/null; then
        log "INFO" "Entry '$node_ip $ingress_host' already exists in /etc/hosts"
        return 0
    fi
    
    # Add the entry to /etc/hosts
    log "INFO" "Adding '$node_ip $ingress_host' to /etc/hosts"
    if echo "$node_ip $ingress_host" | sudo tee -a /etc/hosts > /dev/null; then
        log "SUCCESS" "Entry added successfully to /etc/hosts"
    else
        log "WARN" "Failed to add entry to /etc/hosts. Please add it manually:"
        log "INFO" "echo '$node_ip $ingress_host' | sudo tee -a /etc/hosts"
    fi
}

# Function to test ingress connectivity (wrapper for utils function)
test_ingress_connectivity() {
    if [[ "$ENABLE_INGRESS" != "true" ]]; then
        log "INFO" "Ingress disabled, skipping connectivity test"
        return 0
    fi
    
    log "STEP" "Testing Ingress connectivity"
    
    # Wait for ingress to be ready
    local ingress_name="$HELM_RELEASE_NAME"
    local max_wait=120
    local wait_interval=5
    local elapsed=0
    
    while [[ $elapsed -lt $max_wait ]]; do
        if kubectl_cmd get ingress "$ingress_name" -n "$NAMESPACE" &>/dev/null; then
            local ingress_address=$(kubectl_cmd get ingress "$ingress_name" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
            local ingress_hostname=$(kubectl_cmd get ingress "$ingress_name" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
            
            if [[ -n "$ingress_address" || -n "$ingress_hostname" ]]; then
                log "SUCCESS" "Ingress is ready"
                if [[ -n "$ingress_address" ]]; then
                    log "INFO" "Ingress IP: $ingress_address"
                fi
                if [[ -n "$ingress_hostname" ]]; then
                    log "INFO" "Ingress Hostname: $ingress_hostname"
                fi
                return 0
            fi
        fi
        
        sleep "$wait_interval"
        elapsed=$((elapsed + wait_interval))
        log "DEBUG" "Waiting for ingress to be ready... (${elapsed}s elapsed)"
    done
    
    log "WARN" "Ingress not ready after ${max_wait}s, but deployment may still work"
    return 0
}

# Override deploy_grafana_common to use MicroK8s wrapper functions
deploy_grafana_common() {
    local namespace="${1:-${GRAFANA_NAMESPACE:-grafana}}"
    local helm_release_name="${2:-${HELM_RELEASE_NAME:-grafana}}"
    local project_root="${3:-$PROJECT_ROOT}"
    local enable_ingress="${4:-${ENABLE_INGRESS:-true}}"
    local ingress_class="${5:-${INGRESS_CLASS:-public}}"
    local ingress_host="${6:-${INGRESS_HOST:-grafana.local}}"
    local ingress_path="${7:-${INGRESS_PATH:-/}}"
    local ingress_path_type="${8:-${INGRESS_PATH_TYPE:-Prefix}}"
    
    log "HEADER" "Deploying Grafana"
    
    local values_file="/tmp/helm-values/official-grafana.yaml"
    local chart_name="grafana/grafana"
    local ingress_file="$project_root/ingress.yaml"
    
    # Check if release already exists
    if helm_cmd list -n "$namespace" | grep -q "^$helm_release_name\s"; then
        log "WARN" "Helm release $helm_release_name already exists in namespace $namespace"
        
        local current_status=$(helm_cmd status "$helm_release_name" -n "$namespace" --show-resources=false 2>/dev/null | grep "STATUS:" | awk '{print $2}')
        log "INFO" "Current release status: $current_status"
        
        if [[ "$current_status" == "deployed" ]]; then
            log "INFO" "Upgrading existing release"
            helm_cmd upgrade "$helm_release_name" "$chart_name" \
                --namespace "$namespace" \
                --values "$values_file" \
                --wait \
                --timeout 10m
        else
            log "WARN" "Release is not in deployed state, attempting to reinstall..."
            helm_cmd uninstall "$helm_release_name" --namespace "$namespace"
            sleep 5
            deploy_grafana_common "$namespace" "$helm_release_name" "$project_root" "$enable_ingress" "$ingress_class" "$ingress_host" "$ingress_path" "$ingress_path_type"
            return
        fi
    else
        log "INFO" "Installing new Grafana release"
        
        # Actual deployment
        log "INFO" "Starting Grafana deployment..."
        helm_cmd install "$helm_release_name" "$chart_name" \
            --namespace "$namespace" \
            --values "$values_file" \
            --wait \
            --timeout 10m
    fi
    
    if [[ $? -eq 0 ]]; then
        log "SUCCESS" "Grafana deployment completed successfully"
        
        # Apply ingress configuration if enabled
        if [[ "$enable_ingress" == "true" ]]; then
            log "STEP" "Applying ingress configuration"
            if [[ -f "$ingress_file" ]]; then
                # Copy ingress file to VM
                multipass transfer "$ingress_file" "$MICROK8S_VM:/tmp/ingress.yaml"
                kubectl_cmd apply -f /tmp/ingress.yaml
                if [[ $? -eq 0 ]]; then
                    log "SUCCESS" "Ingress configuration applied successfully"
                else
                    log "WARN" "Failed to apply ingress configuration, but deployment may still work"
                fi
            else
                log "WARN" "Ingress file not found at $ingress_file, skipping ingress setup"
            fi
        fi
    else
        log_and_exit "ERROR" "Grafana deployment failed"
    fi
}

# Override verify_deployment_common to use MicroK8s wrapper functions
verify_deployment_common() {
    local namespace="${1:-${GRAFANA_NAMESPACE:-grafana}}"
    local helm_release_name="${2:-${HELM_RELEASE_NAME:-grafana}}"
    local enable_ingress="${3:-${ENABLE_INGRESS:-true}}"
    
    log "HEADER" "Verifying Deployment"
    
    # Wait for pods to be ready
    log "STEP" "Waiting for Grafana pods to be ready"
    local elapsed=0
    local timeout=300
    local interval=10
    while [[ $elapsed -lt $timeout ]]; do
        local pod_status=$(kubectl_cmd get pods -n "$namespace" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "")
        if [[ "$pod_status" == "Running" ]]; then
            log "SUCCESS" "Grafana pod is running"
            break
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        log "DEBUG" "Waiting for Grafana pod to be ready... (${elapsed}s elapsed)"
    done
    
    # Check pod status
    log "STEP" "Checking pod status"
    local pod_status=$(kubectl_cmd get pods -n "$namespace" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.phase}')
    if [[ "$pod_status" != "Running" ]]; then
        log_and_exit "ERROR" "Grafana pod is not running (status: $pod_status)"
    fi
    log "SUCCESS" "Grafana pod is running"
    
    # Check service status
    log "STEP" "Checking service status"
    local service_type=$(kubectl_cmd get service "$helm_release_name" -n "$namespace" -o jsonpath='{.spec.type}')
    local service_port=$(kubectl_cmd get service "$helm_release_name" -n "$namespace" -o jsonpath='{.spec.ports[0].port}')
    
    if [[ "$service_type" == "ClusterIP" ]]; then
        log "SUCCESS" "Service type: $service_type, Port: $service_port (Ingress mode)"
    elif [[ "$service_type" == "NodePort" ]]; then
        local nodeport=$(kubectl_cmd get service "$helm_release_name" -n "$namespace" -o jsonpath='{.spec.ports[0].nodePort}')
        log "SUCCESS" "Service type: $service_type, NodePort: $nodeport"
    else
        log "INFO" "Service type: $service_type, Port: $service_port"
    fi
    
    # Check ingress status if enabled
    if [[ "$enable_ingress" == "true" ]]; then
        log "STEP" "Checking ingress status"
        local ingress_name="$helm_release_name"
        if kubectl_cmd get ingress "$ingress_name" -n "$namespace" &>/dev/null; then
            local ingress_host=$(kubectl_cmd get ingress "$ingress_name" -n "$namespace" -o jsonpath='{.spec.rules[0].host}')
            local ingress_class=$(kubectl_cmd get ingress "$ingress_name" -n "$namespace" -o jsonpath='{.spec.ingressClassName}')
            log "SUCCESS" "Ingress configured - Host: $ingress_host, Class: $ingress_class"
        else
            log "WARN" "Ingress resource not found"
        fi
    fi
    
    log "SUCCESS" "Deployment verification completed"
}

# Function to deploy Grafana (wrapper for utils function)
deploy_grafana() {
    deploy_grafana_common "$NAMESPACE" "$HELM_RELEASE_NAME" "$PROJECT_ROOT" "$ENABLE_INGRESS" "$INGRESS_CLASS" "$INGRESS_HOST" "$INGRESS_PATH" "$INGRESS_PATH_TYPE"
}

# Function to verify deployment (wrapper for utils function)
verify_deployment() {
    verify_deployment_common "$NAMESPACE" "$HELM_RELEASE_NAME" "$ENABLE_INGRESS"
}


# =============================================================================
# MAIN FUNCTION
# =============================================================================

# Function to display usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Deploy Grafana using official Helm chart with optional features.

OPTIONS:
    -h, --help                Show this help message
    # --disable-db-fix          Skip database permission fixes (DB fix disabled - not needed)
    --disable-ingress         Deploy without Ingress (use NodePort instead)
    --ingress-class CLASS     Specify Ingress class (default: public)
    --ingress-host HOST       Specify Ingress host (default: grafana.local)
    -n, --namespace NAME      Kubernetes namespace [default: grafana]
    -r, --release-name NAME   Helm release name [default: grafana]
    -v, --verbose             Enable verbose logging

EXAMPLES:
    $0                         # Deploy with all features enabled
    $0 --disable-ingress       # Deploy without Ingress
    # $0 --disable-db-fix        # Deploy without database fixes (DB fix disabled - not needed)
    $0 --ingress-class nginx   # Deploy with specific Ingress class
    $0 --ingress-host grafana.example.com  # Deploy with custom host

ENVIRONMENT VARIABLES:
    GRAFANA_NAMESPACE           Kubernetes namespace
    # ENABLE_DB_FIX              Enable database fixes (true/false) (DB fix disabled - not needed)
    ENABLE_INGRESS             Enable ingress (true/false)
    INGRESS_CLASS              Ingress class name (default: public for MicroK8s, nginx otherwise)
    INGRESS_HOST               Ingress hostname
    DB_HOST                   PostgreSQL host
    DB_PORT                   PostgreSQL port
    DB_NAME                   Grafana database name
    DB_USER                   Grafana database user
    DB_PASSWORD               Grafana database password
    POSTGRES_USER             PostgreSQL superuser
    POSTGRES_PASSWORD         PostgreSQL superuser password

EOF
}

# Function to parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            # --disable-db-fix)
            #     export ENABLE_DB_FIX="false"
            #     shift
            #     ;;
            --disable-ingress)
                export ENABLE_INGRESS="false"
                shift
                ;;
            --ingress-class)
                export INGRESS_CLASS="$2"
                shift 2
                ;;
            --ingress-host)
                export INGRESS_HOST="$2"
                shift 2
                ;;
            -n|--namespace)
                export NAMESPACE="$2"
                shift 2
                ;;
            -r|--release-name)
                export HELM_RELEASE_NAME="$2"
                shift 2
                ;;
            -v|--verbose)
                export DEBUG_MODE="true"
                shift
                ;;
            *)
                log_and_exit "ERROR" "Unknown option: $1"
                ;;
        esac
    done
}

# Override init_script to use MicroK8s wrapper functions
init_script() {
    local script_name=$(basename "$0")
    
    log "HEADER" "Starting $script_name"
    log "DEBUG" "Script directory: $(dirname "$0")"
    log "DEBUG" "Working directory: $(pwd)"
    log "INFO" "Using MicroK8s via Multipass (VM: $MICROK8S_VM)"
    
    # Set up error handling
    setup_error_handling
    
    # Load environment variables
    load_env
    
    # Check prerequisites using MicroK8s wrappers
    log "INFO" "Checking kubectl availability..."
    if command -v multipass &> /dev/null; then
        log "SUCCESS" "multipass is available"
    else
        log_and_exit "ERROR" "multipass is not installed or not in PATH"
    fi
    
    log "INFO" "Checking MicroK8s VM status..."
    if multipass list | grep -q "^$MICROK8S_VM.*Running"; then
        log "SUCCESS" "MicroK8s VM '$MICROK8S_VM' is running"
    else
        log_and_exit "ERROR" "MicroK8s VM '$MICROK8S_VM' is not running. Start it with: multipass start $MICROK8S_VM"
    fi
    
    log "INFO" "Checking kubectl in MicroK8s..."
    if kubectl_cmd version --client &> /dev/null; then
        local kubectl_version=$(kubectl_cmd version --client 2>/dev/null || echo "unknown")
        log "SUCCESS" "kubectl is available in MicroK8s: $kubectl_version"
    else
        log_and_exit "ERROR" "kubectl is not available in MicroK8s"
    fi
    
    log "INFO" "Checking helm in MicroK8s..."
    local helm_version=$(helm_cmd version --short 2>/dev/null || echo "unknown")
    log "SUCCESS" "helm is available in MicroK8s: $helm_version"
    
    log "INFO" "Checking Kubernetes cluster connectivity..."
    if kubectl_cmd cluster-info &> /dev/null; then
        local cluster_info=$(kubectl_cmd cluster-info)
        log "SUCCESS" "Cluster connectivity confirmed"
        log "DEBUG" "Cluster info: $cluster_info"
    else
        log_and_exit "ERROR" "Cannot connect to Kubernetes cluster"
    fi
    
    log "SUCCESS" "Script initialization completed"
}

# Main deployment function
main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Initialize script
    init_script
    
    # Start deployment process
    log "HEADER" "Starting Grafana Deployment"
    log "INFO" "Chart: Official Grafana Helm Chart"
    log "INFO" "Namespace: $NAMESPACE"
    log "INFO" "Release Name: $HELM_RELEASE_NAME"
    # log "INFO" "Database Fix Enabled: $ENABLE_DB_FIX"  # DB fix disabled - not needed
    log "INFO" "Ingress Enabled: $ENABLE_INGRESS"
    log "INFO" "Ingress Class: $INGRESS_CLASS"
    log "INFO" "Ingress Host: $INGRESS_HOST"
    log "INFO" "Database Host: $DB_HOST"
    log "INFO" "Database Port: $DB_PORT"
    log "INFO" "Database Name: $DB_NAME"
    log "INFO" "Database User: $DB_USER"
    
    # Check ingress controller if ingress is enabled
    if [[ "$ENABLE_INGRESS" == "true" ]]; then
        check_ingress_controller
    fi
    
    # Setup database permissions (disabled - not needed)
    # setup_database_permissions
    
    # Test database connectivity (disabled - not needed)
    # test_database_connectivity
    
    # Setup Helm repository
    log "HEADER" "Setting up Helm Repository"
    if helm_cmd repo list | grep -q "^grafana\s"; then
        log "INFO" "Helm repository grafana already exists, updating..."
        helm_cmd repo update grafana
    else
        helm_cmd repo add grafana "https://grafana.github.io/helm-charts"
        if [[ $? -eq 0 ]]; then
            log "SUCCESS" "Helm repository grafana added successfully"
        else
            log_and_exit "ERROR" "Failed to add Helm repository grafana"
        fi
    fi
    
    # Create namespace
    log "HEADER" "Setting up Namespace"
    if kubectl_cmd get namespace "$NAMESPACE" &> /dev/null; then
        log "INFO" "Namespace $NAMESPACE already exists"
    else
        log "INFO" "Creating namespace: $NAMESPACE"
        kubectl_cmd create namespace "$NAMESPACE"
        if [[ $? -eq 0 ]]; then
            log "SUCCESS" "Namespace $NAMESPACE created successfully"
        else
            log_and_exit "ERROR" "Failed to create namespace $NAMESPACE"
        fi
    fi
    
    # Copy helm-values to VM
    log "INFO" "Copying helm-values to MicroK8s VM"
    if multipass transfer -r "$PROJECT_ROOT/helm-values/" "$MICROK8S_VM:/tmp/helm-values/"; then
        log "SUCCESS" "Helm values copied successfully"
    else
        log_and_exit "ERROR" "Failed to copy helm values to VM"
    fi
    
    # Deploy Grafana
    deploy_grafana
    
    # Verify deployment
    verify_deployment
    
    # Test ingress connectivity
    test_ingress_connectivity
    
    # Generate access information
    log "HEADER" "Deployment Information"
    log "INFO" "🎉 Grafana deployment completed successfully!"
    echo ""
    
    if [[ "$ENABLE_INGRESS" == "true" ]]; then
        log "INFO" "🌐 Primary Access (Ingress): http://$INGRESS_HOST"
        log "INFO" "📊 Fallback Access (NodePort): http://10.110.40.193:30030"
        setup_hosts_entry
    else
        log "INFO" "📊 Access Grafana at: http://10.110.40.193:30030"
    fi
    
    echo ""
    log "INFO" "═══════════════════════════════════════════════════════════════"
    log "INFO" "🔐 GRAFANA ADMIN CREDENTIALS"
    log "INFO" "═══════════════════════════════════════════════════════════════"
    log "INFO" ""
    log "INFO" "👤 Admin Username: admin"
    log "INFO" ""
    log "INFO" "🔑 Admin Password:"
    echo ""
    
    # Retrieve and display the admin password from Kubernetes secret
    local admin_password=$(kubectl_cmd get secret grafana -n "$NAMESPACE" -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || echo "Failed to retrieve password")
    
    if [[ "$admin_password" != "Failed to retrieve password" ]]; then
        log "INFO" "   $admin_password"
        echo ""
        log "INFO" "💡 To retrieve the password manually, run:"
        log "INFO" "   kubectl get secret grafana -n $NAMESPACE -o jsonpath='{.data.admin-password}' | base64 -d"
    else
        log "WARN" "   Failed to retrieve password from secret"
        log "INFO" "💡 To retrieve the password manually, run:"
        log "INFO" "   kubectl get secret grafana -n $NAMESPACE -o jsonpath='{.data.admin-password}' | base64 -d"
    fi
    
    echo ""
    log "INFO" "═══════════════════════════════════════════════════════════════"
    echo ""
    log "INFO" "🔍 Run verification: ./scripts/verify.sh"
    log "INFO" "🧹 Run cleanup: ./scripts/cleanup.sh"
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

# Run main function with all arguments
main "$@"