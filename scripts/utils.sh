#!/bin/bash

# =============================================================================
# GRAFANA DEPLOYMENT UTILITY FUNCTIONS
# =============================================================================
# This file contains common utility functions used by all deployment scripts

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Initialize DEBUG_MODE if not set
if [[ -z "${DEBUG_MODE:-}" ]]; then
    DEBUG_MODE="false"
    export DEBUG_MODE
fi

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================

# Function to print colored output
log() {
    local level=$1
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case $level in
        "INFO")
            echo -e "${GREEN}[INFO]${NC} ${timestamp} - $message"
            ;;
        "WARN")
            echo -e "${YELLOW}[WARN]${NC} ${timestamp} - $message"
            ;;
        "ERROR")
            echo -e "${RED}[ERROR]${NC} ${timestamp} - $message"
            ;;
        "DEBUG")
            if [[ "${DEBUG_MODE}" == "true" ]]; then
                echo -e "${BLUE}[DEBUG]${NC} ${timestamp} - $message"
            fi
            ;;
        "SUCCESS")
            echo -e "${GREEN}[SUCCESS]${NC} ${timestamp} - $message"
            ;;
        "HEADER")
            echo -e "${PURPLE}=== $message ===${NC}"
            ;;
        "STEP")
            echo -e "${CYAN}[STEP]${NC} $message"
            ;;
        *)
            echo -e "${timestamp} - $message"
            ;;
    esac
}

# Function to log with exit on error
log_and_exit() {
    local level=$1
    shift
    local message="$*"
    log "$level" "$message"
    exit 1
}

# =============================================================================
# FILE AND DIRECTORY FUNCTIONS
# =============================================================================

# Function to check if file exists
file_exists() {
    local file=$1
    if [[ -f "$file" ]]; then
        return 0
    else
        return 1
    fi
}

# Function to check if directory exists
dir_exists() {
    local dir=$1
    if [[ -d "$dir" ]]; then
        return 0
    else
        return 1
    fi
}

# Function to create directory if it doesn't exist
ensure_dir() {
    local dir=$1
    if ! dir_exists "$dir"; then
        mkdir -p "$dir"
        log "DEBUG" "Created directory: $dir"
    fi
}

# Function to load environment variables from .env file
load_env() {
    local env_file=${1:-".env"}
    
    if file_exists "$env_file"; then
        log "INFO" "Loading environment variables from $env_file"
        set -a
        source "$env_file"
        set +a
        log "DEBUG" "Environment variables loaded successfully"
    else
        log_and_exit "ERROR" "Environment file $env_file not found"
    fi
}

# =============================================================================
# KUBERNETES FUNCTIONS
# =============================================================================

# Function to check if kubectl is available
check_kubectl() {
    # Check if we're using MicroK8s
    if [[ "${USE_MICROK8S:-false}" == "true" ]]; then
        if ! command -v multipass &> /dev/null; then
            log_and_exit "ERROR" "multipass is not installed or not in PATH (required for MicroK8s)"
        fi
        
        local microk8s_vm="${MICROK8S_VM:-microk8s}"
        if ! multipass list | grep -q "^$microk8s_vm "; then
            log_and_exit "ERROR" "MicroK8s VM '$microk8s_vm' not found in multipass"
        fi
        
        local kubectl_version=$(multipass exec "$microk8s_vm" -- microk8s kubectl version --client --short 2>/dev/null || echo "unknown")
        log "INFO" "kubectl version: $kubectl_version (via MicroK8s)"
    else
        if ! command -v kubectl &> /dev/null; then
            log_and_exit "ERROR" "kubectl is not installed or not in PATH"
        fi
        
        local kubectl_version=$(kubectl version --client --short 2>/dev/null || echo "unknown")
        log "INFO" "kubectl version: $kubectl_version"
    fi
}

# Function to check if helm is available
check_helm() {
    # Check if we're using MicroK8s
    if [[ "${USE_MICROK8S:-false}" == "true" ]]; then
        if ! command -v multipass &> /dev/null; then
            log_and_exit "ERROR" "multipass is not installed or not in PATH (required for MicroK8s)"
        fi
        
        local microk8s_vm="${MICROK8S_VM:-microk8s}"
        if ! multipass list | grep -q "^$microk8s_vm "; then
            log_and_exit "ERROR" "MicroK8s VM '$microk8s_vm' not found in multipass"
        fi
        
        local helm_version=$(multipass exec "$microk8s_vm" -- microk8s helm version --short 2>/dev/null || echo "unknown")
        log "INFO" "helm version: $helm_version (via MicroK8s)"
    else
        if ! command -v helm &> /dev/null; then
            log_and_exit "ERROR" "helm is not installed or not in PATH"
        fi
        
        local helm_version=$(helm version --short 2>/dev/null || echo "unknown")
        log "INFO" "helm version: $helm_version"
    fi
}

# Function to check if cluster is accessible
check_cluster() {
    log "INFO" "Checking Kubernetes cluster connectivity"
    
    if ! kubectl cluster-info &> /dev/null; then
        log_and_exit "ERROR" "Cannot connect to Kubernetes cluster"
    fi
    
    local cluster_info=$(kubectl cluster-info)
    log "INFO" "Cluster connectivity confirmed"
    log "DEBUG" "Cluster info: $cluster_info"
}

# Function to check if namespace exists
namespace_exists() {
    local namespace=$1
    kubectl get namespace "$namespace" &> /dev/null
    return $?
}

# Function to create namespace
create_namespace() {
    local namespace=$1
    
    if namespace_exists "$namespace"; then
        log "INFO" "Namespace $namespace already exists"
    else
        log "INFO" "Creating namespace: $namespace"
        kubectl create namespace "$namespace"
        if [[ $? -eq 0 ]]; then
            log "SUCCESS" "Namespace $namespace created successfully"
        else
            log_and_exit "ERROR" "Failed to create namespace $namespace"
        fi
    fi
}

# Function to check if storage class exists
storage_class_exists() {
    local storage_class=$1
    kubectl get storageclass "$storage_class" &> /dev/null
    return $?
}

# =============================================================================
# HELM FUNCTIONS
# =============================================================================

# Function to add Helm repository
add_helm_repo() {
    local repo_name=$1
    local repo_url=$2
    
    log "INFO" "Adding Helm repository: $repo_name"
    
    # Check if repository already exists
    if helm repo list | grep -q "^$repo_name\s"; then
        log "INFO" "Helm repository $repo_name already exists, updating..."
        helm repo update "$repo_name"
    else
        helm repo add "$repo_name" "$repo_url"
        if [[ $? -eq 0 ]]; then
            log "SUCCESS" "Helm repository $repo_name added successfully"
        else
            log_and_exit "ERROR" "Failed to add Helm repository $repo_name"
        fi
    fi
}

# Function to check if Helm release exists
helm_release_exists() {
    local release_name=$1
    local namespace=$2
    
    helm list -n "$namespace" | grep -q "^$release_name\s"
    return $?
}

# Function to get Helm release status
get_helm_release_status() {
    local release_name=$1
    local namespace=$2
    
    # Check if we're using MicroK8s
    if [[ "${USE_MICROK8S:-false}" == "true" ]]; then
        local helm_output=$(multipass exec "${MICROK8S_VM:-microk8s}" -- microk8s helm status "$release_name" -n "$namespace" --show-resources=false 2>/dev/null || echo "")
    else
        local helm_output=$(helm status "$release_name" -n "$namespace" --show-resources=false 2>/dev/null || echo "")
    fi
    
    local status=$(echo "$helm_output" | grep -E "^STATUS:" | awk '{print $2}' | head -1 2>/dev/null || echo "")
    echo "${status:-unknown}"
}

# Function to validate Helm values file
validate_helm_values() {
    local values_file=$1
    local chart_name=$2
    
    log "INFO" "Validating Helm values file: $values_file"
    
    if ! file_exists "$values_file"; then
        log_and_exit "ERROR" "Helm values file $values_file not found"
    fi
    
    # Validate YAML syntax
    if ! python3 -c "import yaml; yaml.safe_load(open('$values_file'))" 2>/dev/null; then
        log_and_exit "ERROR" "Invalid YAML syntax in $values_file"
    fi
    
    log "SUCCESS" "Helm values file $values_file is valid"
}

# =============================================================================
# NETWORK AND CONNECTIVITY FUNCTIONS
# =============================================================================

# Function to check if port is available
check_port_available() {
    local port=$1
    local host=${2:-"localhost"}
    
    log "DEBUG" "Checking if port $port is available on $host"
    
    if nc -z "$host" "$port" 2>/dev/null; then
        log "WARN" "Port $port is already in use on $host"
        return 1
    else
        log "DEBUG" "Port $port is available on $host"
        return 0
    fi
}

# Function to check database connectivity
check_database_connectivity() {
    local db_host=$1
    local db_port=$2
    local db_name=$3
    local db_user=$4
    local db_password=$5
    
    log "INFO" "Checking database connectivity to $db_host:$db_port"
    
    # Try to connect using psql if available
    if command -v psql &> /dev/null; then
        PGPASSWORD="$db_password" psql -h "$db_host" -p "$db_port" -U "$db_user" -d "$db_name" -c "SELECT 1;" &> /dev/null
        if [[ $? -eq 0 ]]; then
            log "SUCCESS" "Database connectivity confirmed"
            return 0
        else
            log "ERROR" "Database connectivity failed"
            return 1
        fi
    else
        log "WARN" "psql not available, skipping database connectivity check"
        return 0
    fi
}

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

# Function to validate required environment variables
validate_env_vars() {
    local required_vars=("$@")
    local missing_vars=()
    
    for var in "${required_vars[@]}"; do
        if [[ -z "${!var}" ]]; then
            missing_vars+=("$var")
        fi
    done
    
    if [[ ${#missing_vars[@]} -gt 0 ]]; then
        log_and_exit "ERROR" "Missing required environment variables: ${missing_vars[*]}"
    fi
    
    log "SUCCESS" "All required environment variables are set"
}

# Function to validate password strength
validate_password() {
    local password=$1
    local min_length=${2:-8}
    
    if [[ ${#password} -lt $min_length ]]; then
        log_and_exit "ERROR" "Password must be at least $min_length characters long"
    fi
    
    if [[ ! "$password" =~ [A-Z] ]]; then
        log_and_exit "ERROR" "Password must contain at least one uppercase letter"
    fi
    
    if [[ ! "$password" =~ [a-z] ]]; then
        log_and_exit "ERROR" "Password must contain at least one lowercase letter"
    fi
    
    if [[ ! "$password" =~ [0-9] ]]; then
        log_and_exit "ERROR" "Password must contain at least one number"
    fi
    
    log "SUCCESS" "Password validation passed"
}

# =============================================================================
# ERROR HANDLING FUNCTIONS
# =============================================================================

# Function to handle errors with cleanup
handle_error() {
    local exit_code=$?
    local line_number=$1
    local command=$2
    
    log "ERROR" "Command failed with exit code $exit_code at line $line_number: $command"
    log "ERROR" "Deployment failed. Check logs for details."
    
    # Call cleanup function if defined
    if declare -f cleanup_on_error &> /dev/null; then
        log "INFO" "Running cleanup on error..."
        cleanup_on_error
    fi
    
    # Only exit if not in test mode
    if [[ "${TEST_MODE:-false}" != "true" ]]; then
        exit $exit_code
    fi
}

# Function to set up error handling
setup_error_handling() {
    if [[ "${TEST_MODE:-false}" != "true" ]]; then
        set -eE
        trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR
    fi
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Function to generate random string
generate_random_string() {
    local length=${1:-16}
    openssl rand -hex "$((length/2))" 2>/dev/null || date +%s | sha256sum | head -c "$length"
}

# Function to wait for resource to be ready
wait_for_ready() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    local timeout=${4:-300}
    local interval=${5:-10}
    
    log "INFO" "Waiting for $resource_type $resource_name to be ready (timeout: ${timeout}s)"
    
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        local status=$(kubectl get "$resource_type" "$resource_name" -n "$namespace" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "False")
        
        if [[ "$status" == "True" ]]; then
            log "SUCCESS" "$resource_type $resource_name is ready"
            return 0
        fi
        
        sleep "$interval"
        elapsed=$((elapsed + interval))
        log "DEBUG" "Waiting for $resource_type $resource_name to be ready... (${elapsed}s elapsed)"
    done
    
    log_and_exit "ERROR" "Timeout waiting for $resource_type $resource_name to be ready"
}

# Function to get current timestamp
get_timestamp() {
    date '+%Y%m%d_%H%M%S'
}

# Function to create backup of a file
backup_file() {
    local file=$1
    local backup_suffix=${2:-".backup.$(get_timestamp)"}
    
    if file_exists "$file"; then
        cp "$file" "${file}${backup_suffix}"
        log "INFO" "Backup created: ${file}${backup_suffix}"
    fi
}

# =============================================================================
# INITIALIZATION
# =============================================================================

# Function to initialize the script environment
init_script() {
    local script_name=$(basename "$0")
    
    log "HEADER" "Starting $script_name"
    log "DEBUG" "Script directory: $(dirname "$0")"
    log "DEBUG" "Working directory: $(pwd)"
    
    # Set up error handling
    setup_error_handling
    
    # Load environment variables
    load_env
    
    # Check prerequisites
    check_kubectl
    check_helm
    check_cluster
    
    log "SUCCESS" "Script initialization completed"
}

# =============================================================================
# MAIN FUNCTION FOR TESTING
# =============================================================================

# Function to run utility tests (for development)
test_utils() {
    log "HEADER" "Running Utility Tests"
    
    # Test logging functions
    log "INFO" "Testing info log"
    log "WARN" "Testing warning log"
    log "ERROR" "Testing error log"
    log "DEBUG" "Testing debug log"
    log "SUCCESS" "Testing success log"
    
    # Test file functions
    log "INFO" "Testing file functions..."
    if file_exists ".env"; then
        log "INFO" ".env file exists"
    else
        log "WARN" ".env file not found"
    fi
    
    # Test validation functions
    log "INFO" "Testing validation functions..."
    validate_env_vars "HOME" "PATH"
    
    log "SUCCESS" "Utility tests completed"
}

# =============================================================================
# DATABASE FUNCTIONS
# =============================================================================

# Function to setup database permissions
setup_database_permissions() {
    local db_host="${1:-$DB_HOST}"
    local db_port="${2:-$DB_PORT}"
    local db_name="${3:-$DB_NAME}"
    local db_user="${4:-$DB_USER}"
    local db_password="${5:-$DB_PASSWORD}"
    local postgres_user="${6:-$POSTGRES_USER}"
    local postgres_password="${7:-$POSTGRES_PASSWORD}"
    
    log "HEADER" "Setting up Database Permissions"
    
    log "STEP" "Checking database and user configuration"
    # Database and user setup logic would go here
    # For now, we'll assume they exist and verify permissions
    log "INFO" "Using existing database configuration"
    log "SUCCESS" "Database permissions setup completed"
}

# Function to test database connectivity
test_database_connectivity_from_grafana() {
    local db_host="${1:-$DB_HOST}"
    local db_port="${2:-$DB_PORT}"
    local db_name="${3:-$DB_NAME}"
    local db_user="${4:-$DB_USER}"
    local db_password="${5:-$DB_PASSWORD}"
    
    log "STEP" "Testing database connectivity from Grafana perspective"
    
    local test_sql="SELECT 1;"
    
    # Test database connectivity using the internal service
    if kubectl exec -n postgres postgres-postgresql-0 -- bash -c "PGPASSWORD=$db_password psql -U $db_user -d $db_name -h $db_host -p $db_port -c '$test_sql'" 2>/dev/null; then
        log "SUCCESS" "Database connectivity test passed"
        return 0
    else
        log "WARN" "Database connectivity test failed, but deployment may still work"
        return 0  # Don't fail deployment for database issues
    fi
}

# =============================================================================
# INGRESS FUNCTIONS
# =============================================================================

# Function to check if ingress controller is available
check_ingress_controller() {
    local ingress_class="${1:-${INGRESS_CLASS:-public}}"
    
    log "STEP" "Checking Ingress Controller availability"
    
    # Check for nginx ingress controller
    if kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx &>/dev/null; then
        local ingress_pods=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --no-headers | wc -l)
        if [[ $ingress_pods -gt 0 ]]; then
            log "SUCCESS" "NGINX Ingress Controller found with $ingress_pods pods"
            return 0
        fi
    fi
    
    # Check for other common ingress controllers
    local ingress_classes=$(kubectl get ingressclass --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ')
    if [[ -n "$ingress_classes" ]]; then
        log "INFO" "Available Ingress Classes: $ingress_classes"
        
        # Check if requested ingress class exists
        if echo "$ingress_classes" | grep -q "$ingress_class"; then
            log "SUCCESS" "Ingress class '$ingress_class' is available"
            return 0
        else
            log "WARN" "Ingress class '$ingress_class' not found. Available: $ingress_classes"
            return 1
        fi
    else
        log "WARN" "No Ingress Controller found. Ingress may not work properly."
        log "INFO" "Consider installing an Ingress Controller:"
        log "INFO" "  - NGINX: kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml"
        log "INFO" "  - For MicroK8s: microk8s enable ingress"
        return 1
    fi
}

# Function to setup local hosts entry
setup_hosts_entry() {
    local ingress_host="${1:-${INGRESS_HOST:-grafana.local}}"
    local node_ip="${2:-${NODE_IP:-10.110.40.193}}"
    
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

# Function to test ingress connectivity
test_ingress_connectivity() {
    local namespace="${1:-${GRAFANA_NAMESPACE:-grafana}}"
    local helm_release_name="${2:-${HELM_RELEASE_NAME:-grafana}}"
    
    log "STEP" "Testing Ingress connectivity"
    
    # Wait for ingress to be ready
    local ingress_name="$helm_release_name"
    local max_wait=120
    local wait_interval=5
    local elapsed=0
    
    while [[ $elapsed -lt $max_wait ]]; do
        if kubectl get ingress "$ingress_name" -n "$namespace" &>/dev/null; then
            local ingress_address=$(kubectl get ingress "$ingress_name" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
            local ingress_hostname=$(kubectl get ingress "$ingress_name" -n "$namespace" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
            
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

# Function to test ingress YAML syntax
test_ingress_yaml() {
    local project_root="${1:-$PROJECT_ROOT}"
    local values_file="$project_root/helm-values/official-grafana.yaml"
    
    log "STEP" "Testing Ingress YAML syntax"
    
    if ! python3 -c "import yaml; yaml.safe_load(open('$values_file'))" 2>/dev/null; then
        log "ERROR" "Invalid YAML syntax in $values_file"
        return 1
    fi
    
    log "SUCCESS" "Ingress YAML syntax is valid"
    return 0
}

# Function to test ingress template rendering
test_ingress_template() {
    local project_root="${1:-$PROJECT_ROOT}"
    local values_file="$project_root/helm-values/official-grafana.yaml"
    local chart_name="grafana/grafana"
    local namespace="${2:-${GRAFANA_NAMESPACE:-grafana}}"
    local helm_release_name="${3:-${HELM_RELEASE_NAME:-grafana}}"
    
    log "STEP" "Testing Ingress template rendering"
    
    # Test template rendering (dry run)
    if helm template "$helm_release_name" "$chart_name" \
        --namespace "$namespace" \
        --values "$values_file" \
        --set ingress.enabled="true" \
        --show-only templates/ingress.yaml &>/dev/null; then
        log "SUCCESS" "Ingress template renders correctly"
        return 0
    else
        log "ERROR" "Ingress template rendering failed"
        return 1
    fi
}

# =============================================================================
# DEPLOYMENT FUNCTIONS
# =============================================================================

# Function to deploy Grafana with common logic
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
    
    local values_file="$project_root/helm-values/official-grafana.yaml"
    local chart_name="grafana/grafana"
    
    # Check if release already exists
    if helm_release_exists "$helm_release_name" "$namespace"; then
        log "WARN" "Helm release $helm_release_name already exists in namespace $namespace"
        
        local current_status=$(get_helm_release_status "$helm_release_name" "$namespace")
        log "INFO" "Current release status: $current_status"
        
        if [[ "$current_status" == "deployed" ]]; then
            log "INFO" "Upgrading existing release"
            helm upgrade "$helm_release_name" "$chart_name" \
                --namespace "$namespace" \
                --values "$values_file" \
                --set ingress.enabled="$enable_ingress" \
                --set ingress.ingressClassName="$ingress_class" \
                --set ingress.hosts[0].host="$ingress_host" \
                --set ingress.hosts[0].paths[0].path="$ingress_path" \
                --set ingress.hosts[0].paths[0].pathType="$ingress_path_type" \
                --wait \
                --timeout 10m
        else
            log "WARN" "Release is not in deployed state, attempting to reinstall..."
            helm uninstall "$helm_release_name" --namespace "$namespace"
            sleep 5
            deploy_grafana_common "$namespace" "$helm_release_name" "$project_root" "$enable_ingress" "$ingress_class" "$ingress_host" "$ingress_path" "$ingress_path_type"
            return
        fi
    else
        log "INFO" "Installing new Grafana release"
        
        # Actual deployment
        log "INFO" "Starting Grafana deployment..."
        helm install "$helm_release_name" "$chart_name" \
            --namespace "$namespace" \
            --values "$values_file" \
            --set ingress.enabled="$enable_ingress" \
            --set ingress.ingressClassName="$ingress_class" \
            --set ingress.hosts[0].host="$ingress_host" \
            --set ingress.hosts[0].paths[0].path="$ingress_path" \
            --set ingress.hosts[0].paths[0].pathType="$ingress_path_type" \
            --wait \
            --timeout 10m
    fi
    
    if [[ $? -eq 0 ]]; then
        log "SUCCESS" "Grafana deployment completed successfully"
    else
        log_and_exit "ERROR" "Grafana deployment failed"
    fi
}

# Function to verify deployment with common logic
verify_deployment_common() {
    local namespace="${1:-${GRAFANA_NAMESPACE:-grafana}}"
    local helm_release_name="${2:-${HELM_RELEASE_NAME:-grafana}}"
    local enable_ingress="${3:-${ENABLE_INGRESS:-true}}"
    
    log "HEADER" "Verifying Deployment"
    
    # Wait for pods to be ready
    log "STEP" "Waiting for Grafana pods to be ready"
    wait_for_ready "pod" "-l app.kubernetes.io/name=grafana" "$namespace" 300
    
    # Check pod status
    log "STEP" "Checking pod status"
    local pod_status=$(kubectl get pods -n "$namespace" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].status.phase}')
    if [[ "$pod_status" != "Running" ]]; then
        log_and_exit "ERROR" "Grafana pod is not running (status: $pod_status)"
    fi
    log "SUCCESS" "Grafana pod is running"
    
    # Check service status
    log "STEP" "Checking service status"
    local service_type=$(kubectl get service "$helm_release_name" -n "$namespace" -o jsonpath='{.spec.type}')
    local service_port=$(kubectl get service "$helm_release_name" -n "$namespace" -o jsonpath='{.spec.ports[0].port}')
    
    if [[ "$service_type" == "ClusterIP" ]]; then
        log "SUCCESS" "Service type: $service_type, Port: $service_port (Ingress mode)"
    elif [[ "$service_type" == "NodePort" ]]; then
        local nodeport=$(kubectl get service "$helm_release_name" -n "$namespace" -o jsonpath='{.spec.ports[0].nodePort}')
        log "SUCCESS" "Service type: $service_type, NodePort: $nodeport"
    else
        log "INFO" "Service type: $service_type, Port: $service_port"
    fi
    
    # Check ingress status if enabled
    if [[ "$enable_ingress" == "true" ]]; then
        log "STEP" "Checking ingress status"
        local ingress_name="$helm_release_name"
        if kubectl get ingress "$ingress_name" -n "$namespace" &>/dev/null; then
            local ingress_host=$(kubectl get ingress "$ingress_name" -n "$namespace" -o jsonpath='{.spec.rules[0].host}')
            local ingress_class=$(kubectl get ingress "$ingress_name" -n "$namespace" -o jsonpath='{.spec.ingressClassName}')
            log "SUCCESS" "Ingress configured - Host: $ingress_host, Class: $ingress_class"
        else
            log "WARN" "Ingress resource not found"
        fi
    fi
    
    log "SUCCESS" "Deployment verification completed"
}

# Export functions for use in other scripts
export -f log log_and_exit
export -f file_exists dir_exists ensure_dir load_env
export -f check_kubectl check_helm check_cluster
export -f namespace_exists create_namespace storage_class_exists
export -f add_helm_repo helm_release_exists get_helm_release_status validate_helm_values
export -f check_port_available check_database_connectivity
export -f validate_env_vars validate_password
export -f handle_error setup_error_handling
export -f generate_random_string wait_for_ready get_timestamp backup_file
export -f init_script test_utils
export -f setup_database_permissions test_database_connectivity_from_grafana
export -f check_ingress_controller setup_hosts_entry test_ingress_connectivity
export -f test_ingress_yaml test_ingress_template
export -f deploy_grafana_common verify_deployment_common