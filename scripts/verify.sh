#!/bin/bash

# =============================================================================
# GRAFANA DEPLOYMENT VERIFICATION SCRIPT
# =============================================================================
# This script verifies that Grafana deployment is working correctly
# It checks all critical components and generates a comprehensive verification report

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# MicroK8s configuration
USE_MICROK8S=true
MICROK8S_VM="microk8s"

# Source utility functions
source "$SCRIPT_DIR/utils.sh"

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

# Verification configuration
VERIFICATION_REPORT="$PROJECT_ROOT/verification-report-$(get_timestamp).txt"
VERIFICATION_TIMEOUT="${VERIFICATION_TIMEOUT:-300}"
VERIFICATION_RESULTS=()

# Deployment configuration
NAMESPACE="${GRAFANA_NAMESPACE:-grafana}"
HELM_RELEASE_NAME="${HELM_RELEASE_NAME:-grafana}"
CHART_TYPE="${CHART_TYPE:-official}"

# Access configuration
NODE_IP="${NODE_IP:-10.110.40.193}"
SERVICE_HTTP_NODEPORT="${SERVICE_HTTP_NODEPORT:-30030}"
INGRESS_ENABLED="${INGRESS_ENABLED:-true}"
INGRESS_HOST="${INGRESS_HOST:-grafana.local}"

# Set default ingress class based on MicroK8s
if [[ "$USE_MICROK8S" == "true" ]]; then
    INGRESS_CLASS="${INGRESS_CLASS:-public}"
else
    INGRESS_CLASS="${INGRESS_CLASS:-nginx}"
fi

# Determine Grafana URL based on ingress configuration
if [[ "$INGRESS_ENABLED" == "true" ]]; then
    GRAFANA_URL="${EXTERNAL_PROTOCOL:-http}://${INGRESS_HOST}"
else
    GRAFANA_URL="${EXTERNAL_PROTOCOL:-http}://${NODE_IP}:${SERVICE_HTTP_NODEPORT}"
fi

# Database configuration
DB_HOST="${DB_HOST:-postgres-postgresql.postgres.svc.cluster.local}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-grafana}"
DB_USER="${DB_USER:-grafana}"
DB_PASSWORD="${DB_PASSWORD:-grafana_password123}"

# =============================================================================
# VERIFICATION FUNCTIONS
# =============================================================================

# Function to add verification result
add_result() {
    local test_name="$1"
    local status="$2"
    local message="$3"
    local details="${4:-}"
    
    VERIFICATION_RESULTS+=("$test_name|$status|$message|$details")
    
    case "$status" in
        "PASS")
            log "SUCCESS" "✅ $test_name: $message"
            ;;
        "FAIL")
            log "ERROR" "❌ $test_name: $message"
            ;;
        "WARN")
            log "WARN" "⚠️  $test_name: $message"
            ;;
        "SKIP")
            log "INFO" "⏭️  $test_name: $message"
            ;;
    esac
}

# Function to verify namespace exists
verify_namespace() {
    log "STEP" "Verifying namespace: $NAMESPACE"
    
    if namespace_exists "$NAMESPACE"; then
        add_result "Namespace" "PASS" "Namespace $NAMESPACE exists" "kubectl_cmd get namespace $NAMESPACE"
    else
        add_result "Namespace" "FAIL" "Namespace $NAMESPACE does not exist" "kubectl_cmd create namespace $NAMESPACE"
    fi
}

# Function to verify Helm release
verify_helm_release() {
    log "STEP" "Verifying Helm release: $HELM_RELEASE_NAME"
    
    if helm_release_exists "$HELM_RELEASE_NAME" "$NAMESPACE"; then
        local status=$(get_helm_release_status "$HELM_RELEASE_NAME" "$NAMESPACE")
        if [[ "$status" == "deployed" ]]; then
            add_result "Helm Release" "PASS" "Release $HELM_RELEASE_NAME is deployed" "helm_cmd status $HELM_RELEASE_NAME -n $NAMESPACE"
        else
            add_result "Helm Release" "FAIL" "Release $HELM_RELEASE_NAME status: $status" "helm_cmd status $HELM_RELEASE_NAME -n $NAMESPACE"
        fi
    else
        add_result "Helm Release" "FAIL" "Release $HELM_RELEASE_NAME does not exist" "helm_cmd install $HELM_RELEASE_NAME -n $NAMESPACE"
    fi
}

# Function to verify pod status
verify_pods() {
    log "STEP" "Verifying Grafana pods"
    
    # Use different selectors based on chart type
    local pod_selector=""
    if [[ "$CHART_TYPE" == "official" ]]; then
        pod_selector="app.kubernetes.io/name=grafana"
    else
        pod_selector="app.kubernetes.io/name=grafana"
    fi
    
    local pod_count=$(kubectl_cmd get pods -n "$NAMESPACE" -l "$pod_selector" --no-headers | wc -l)
    if [[ $pod_count -eq 0 ]]; then
        add_result "Pods" "FAIL" "No Grafana pods found" "kubectl_cmd get pods -n $NAMESPACE -l $pod_selector"
        return
    fi
    
    local ready_pods=$(kubectl_cmd get pods -n "$NAMESPACE" -l "$pod_selector" -o jsonpath='{.items[*].status.containerStatuses[*].ready}' | tr '\n' ' ' | grep -o true | wc -l)
    local total_pods=$(kubectl_cmd get pods -n "$NAMESPACE" -l "$pod_selector" -o jsonpath='{.items[*].status.containerStatuses[*].ready}' | tr '\n' ' ' | wc -w)
    
    if [[ $ready_pods -eq $total_pods ]] && [[ $total_pods -gt 0 ]]; then
        add_result "Pods" "PASS" "All $total_pods pod(s) are ready" "kubectl_cmd get pods -n $NAMESPACE -l $pod_selector"
    else
        add_result "Pods" "FAIL" "Only $ready_pods/$total_pods pod(s) are ready" "kubectl_cmd describe pods -n $NAMESPACE -l $pod_selector"
    fi
}

# Function to verify service configuration
verify_service() {
    log "STEP" "Verifying Grafana service"
    
    if ! kubectl_cmd get service "$HELM_RELEASE_NAME" -n "$NAMESPACE" &> /dev/null; then
        add_result "Service" "FAIL" "Service $HELM_RELEASE_NAME not found" "kubectl_cmd get service -n $NAMESPACE"
        return
    fi
    
    local service_type=$(kubectl_cmd get service "$HELM_RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.type}')
    local service_port=$(kubectl_cmd get service "$HELM_RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].port}')
    local nodeport=$(kubectl_cmd get service "$HELM_RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.spec.ports[0].nodePort}')
    
    if [[ "$INGRESS_ENABLED" == "true" ]]; then
        if [[ "$service_type" == "ClusterIP" ]]; then
            add_result "Service" "PASS" "Service type: $service_type, Port: $service_port (Ingress mode)" "kubectl_cmd get service $HELM_RELEASE_NAME -n $NAMESPACE -o yaml"
        else
            add_result "Service" "WARN" "Service type is $service_type, expected ClusterIP for Ingress" "kubectl_cmd patch service $HELM_RELEASE_NAME -n $NAMESPACE -p '{\"spec\":{\"type\":\"ClusterIP\"}}'"
        fi
    else
        if [[ "$service_type" == "NodePort" ]]; then
            if [[ "$nodeport" == "$SERVICE_HTTP_NODEPORT" ]]; then
                add_result "Service" "PASS" "Service type: $service_type, NodePort: $nodeport" "kubectl_cmd get service $HELM_RELEASE_NAME -n $NAMESPACE -o yaml"
            else
                add_result "Service" "FAIL" "NodePort mismatch: expected $SERVICE_HTTP_NODEPORT, got $nodeport" "kubectl_cmd edit service $HELM_RELEASE_NAME -n $NAMESPACE"
            fi
        else
            add_result "Service" "FAIL" "Service type is $service_type, expected NodePort" "kubectl_cmd patch service $HELM_RELEASE_NAME -n $NAMESPACE -p '{\"spec\":{\"type\":\"NodePort\"}}'"
        fi
    fi
}

# Function to verify ingress configuration
verify_ingress() {
    if [[ "$INGRESS_ENABLED" != "true" ]]; then
        add_result "Ingress" "SKIP" "Ingress is disabled" "Enable INGRESS_ENABLED to use ingress"
        return
    fi
    
    log "STEP" "Verifying Ingress configuration"
    
    local ingress_name="$HELM_RELEASE_NAME"
    
    if ! kubectl_cmd get ingress "$ingress_name" -n "$NAMESPACE" &> /dev/null; then
        add_result "Ingress" "FAIL" "Ingress $ingress_name not found" "kubectl_cmd get ingress -n $NAMESPACE"
        return
    fi
    
    local ingress_class=$(kubectl_cmd get ingress "$ingress_name" -n "$NAMESPACE" -o jsonpath='{.spec.ingressClassName}')
    local ingress_host=$(kubectl_cmd get ingress "$ingress_name" -n "$NAMESPACE" -o jsonpath='{.spec.rules[0].host}')
    local ingress_path=$(kubectl_cmd get ingress "$ingress_name" -n "$NAMESPACE" -o jsonpath='{.spec.rules[0].http.paths[0].path}')
    local ingress_path_type=$(kubectl_cmd get ingress "$ingress_name" -n "$NAMESPACE" -o jsonpath='{.spec.rules[0].http.paths[0].pathType}')
    
    # Check ingress class - use the configured INGRESS_CLASS
    local expected_class="$INGRESS_CLASS"
    if [[ "$ingress_class" == "$expected_class" ]]; then
        add_result "Ingress Class" "PASS" "Ingress class: $ingress_class" "kubectl_cmd get ingress $ingress_name -n $NAMESPACE -o yaml"
    else
        add_result "Ingress Class" "WARN" "Ingress class is $ingress_class, expected $expected_class" "kubectl_cmd patch ingress $ingress_name -n $NAMESPACE -p '{\"spec\":{\"ingressClassName\":\"$expected_class\"}}'"
    fi
    
    # Check ingress host
    local expected_host="${INGRESS_HOST:-grafana.local}"
    if [[ "$ingress_host" == "$expected_host" ]]; then
        add_result "Ingress Host" "PASS" "Ingress host: $ingress_host" "kubectl_cmd get ingress $ingress_name -n $NAMESPACE -o yaml"
    else
        add_result "Ingress Host" "WARN" "Ingress host is $ingress_host, expected $expected_host" "kubectl_cmd patch ingress $ingress_name -n $NAMESPACE -p '{\"spec\":{\"rules\":[{\"host\":\"$expected_host\",\"http\":{\"paths\":[{\"path\":\"/\",\"pathType\":\"Prefix\",\"backend\":{\"service\":{\"name\":\"$HELM_RELEASE_NAME\",\"port\":{\"number\":3000}}}}]}}'"
    fi
    
    # Check ingress status
    local ingress_address=$(kubectl_cmd get ingress "$ingress_name" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")
    local ingress_hostname=$(kubectl_cmd get ingress "$ingress_name" -n "$NAMESPACE" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || echo "")
    
    if [[ -n "$ingress_address" || -n "$ingress_hostname" ]]; then
        if [[ -n "$ingress_address" ]]; then
            add_result "Ingress Status" "PASS" "Ingress address: $ingress_address" "kubectl_cmd get ingress $ingress_name -n $NAMESPACE"
        else
            add_result "Ingress Status" "PASS" "Ingress hostname: $ingress_hostname" "kubectl_cmd get ingress $ingress_name -n $NAMESPACE"
        fi
    else
        add_result "Ingress Status" "WARN" "Ingress has no address/hostname assigned" "Check ingress controller status"
    fi
}

# Function to verify ingress controller
verify_ingress_controller() {
    if [[ "$INGRESS_ENABLED" != "true" ]]; then
        add_result "Ingress Controller" "SKIP" "Ingress is disabled" "Enable INGRESS_ENABLED to use ingress"
        return
    fi
    
    log "STEP" "Verifying Ingress Controller"
    
    # Check for common ingress controllers
    local ingress_controllers_found=0
    
    # Check NGINX ingress controller in ingress-nginx namespace
    if kubectl_cmd get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx &>/dev/null; then
        local nginx_pods=$(kubectl_cmd get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --no-headers | wc -l)
        local nginx_ready=$(kubectl_cmd get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --no-headers | grep -c "Running" 2>/dev/null || echo "0")
        nginx_ready=$(echo "$nginx_ready" | tr -d '\n' | tr -d ' ')
        
        if [[ $nginx_ready -gt 0 ]]; then
            add_result "Ingress Controller" "PASS" "NGINX Ingress Controller (ingress-nginx): $nginx_ready/$nginx_pods pods running" "kubectl_cmd get pods -n ingress-nginx"
            ingress_controllers_found=$((ingress_controllers_found + 1))
        else
            add_result "Ingress Controller" "WARN" "NGINX Ingress Controller (ingress-nginx) found but no pods running" "kubectl_cmd get pods -n ingress-nginx"
        fi
    fi
    
    # Check MicroK8s ingress controller in ingress namespace
    if kubectl_cmd get namespace ingress &>/dev/null; then
        if kubectl_cmd get pods -n ingress &>/dev/null; then
            local microk8s_pods=$(kubectl_cmd get pods -n ingress --no-headers | wc -l)
            local microk8s_ready=$(kubectl_cmd get pods -n ingress --no-headers | grep -c "Running" 2>/dev/null || echo "0")
            microk8s_ready=$(echo "$microk8s_ready" | tr -d '\n' | tr -d ' ')
            
            if [[ $microk8s_ready -gt 0 ]]; then
                add_result "Ingress Controller" "PASS" "MicroK8s Ingress Controller (ingress): $microk8s_ready/$microk8s_pods pods running" "kubectl_cmd get pods -n ingress"
                ingress_controllers_found=$((ingress_controllers_found + 1))
            else
                add_result "Ingress Controller" "WARN" "MicroK8s Ingress Controller (ingress) found but no pods running" "kubectl_cmd get pods -n ingress"
            fi
        fi
    fi
    
    # Check for other ingress classes
    local ingress_classes=$(kubectl_cmd get ingressclass --no-headers 2>/dev/null | awk '{print $1}' | tr '\n' ' ' | sed 's/ $//')
    if [[ -n "$ingress_classes" ]]; then
        add_result "Ingress Classes" "PASS" "Available ingress classes: $ingress_classes" "kubectl_cmd get ingressclass"
    else
        add_result "Ingress Classes" "WARN" "No ingress classes found" "Install an ingress controller"
    fi
    
    if [[ $ingress_controllers_found -eq 0 ]]; then
        add_result "Ingress Controller" "FAIL" "No ingress controller pods found" "Install NGINX ingress controller or other ingress controller"
    fi
}

# Function to verify persistent storage
verify_persistence() {
    log "STEP" "Verifying persistent storage"
    
    # Use different selectors based on chart type
    local pvc_selector=""
    if [[ "$CHART_TYPE" == "official" ]]; then
        pvc_selector="app.kubernetes.io/name=grafana"
    else
        pvc_selector="app.kubernetes.io/name=grafana"
    fi
    
    local pvc_count=$(kubectl_cmd get pvc -n "$NAMESPACE" -l "$pvc_selector" --no-headers | wc -l)
    if [[ $pvc_count -eq 0 ]]; then
        add_result "Persistence" "WARN" "No PVCs found for Grafana" "Check persistence configuration in values file"
        return
    fi
    
    local bound_pvcs=$(kubectl_cmd get pvc -n "$NAMESPACE" -l "$pvc_selector" -o jsonpath='{.items[*].status.phase}' | tr '\n' ' ' | grep -o Bound | wc -l)
    local total_pvcs=$(kubectl_cmd get pvc -n "$NAMESPACE" -l "$pvc_selector" -o jsonpath='{.items[*].status.phase}' | tr '\n' ' ' | wc -w)
    
    if [[ $bound_pvcs -eq $total_pvcs ]]; then
        local storage_size=$(kubectl_cmd get pvc -n "$NAMESPACE" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[0].spec.resources.requests.storage}')
        add_result "Persistence" "PASS" "All $total_pvcs PVC(s) bound, size: $storage_size" "kubectl_cmd get pvc -n $NAMESPACE -l $pvc_selector"
    else
        add_result "Persistence" "FAIL" "Only $bound_pvcs/$total_pvcs PVC(s) bound" "kubectl_cmd describe pvc -n $NAMESPACE -l $pvc_selector"
    fi
}

# Function to verify resource limits
verify_resources() {
    log "STEP" "Verifying resource limits"
    
    # Use different selectors based on chart type
    local pod_selector=""
    if [[ "$CHART_TYPE" == "official" ]]; then
        pod_selector="app.kubernetes.io/name=grafana"
    else
        pod_selector="app.kubernetes.io/name=grafana"
    fi
    
    local pod_name=$(kubectl_cmd get pods -n "$NAMESPACE" -l "$pod_selector" -o jsonpath='{.items[0].metadata.name}')
    
    if [[ -z "$pod_name" ]]; then
        add_result "Resources" "FAIL" "No Grafana pod found to check resources" "kubectl_cmd get pods -n $NAMESPACE -l $pod_selector"
        return
    fi
    
    local cpu_request=$(kubectl_cmd get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].resources.requests.cpu}')
    local cpu_limit=$(kubectl_cmd get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].resources.limits.cpu}')
    local memory_request=$(kubectl_cmd get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].resources.requests.memory}')
    local memory_limit=$(kubectl_cmd get pod "$pod_name" -n "$NAMESPACE" -o jsonpath='{.spec.containers[0].resources.limits.memory}')
    
    if [[ -n "$cpu_request" && -n "$cpu_limit" && -n "$memory_request" && -n "$memory_limit" ]]; then
        add_result "Resources" "PASS" "Resource limits applied: CPU ${cpu_request}/${cpu_limit}, Memory ${memory_request}/${memory_limit}" "kubectl_cmd describe pod $pod_name -n $NAMESPACE"
    else
        add_result "Resources" "FAIL" "Missing resource limits" "Check resources configuration in values file"
    fi
}

# Function to verify database integration
verify_database_integration() {
    log "STEP" "Verifying database integration"
    
    # Check Grafana logs for database connection
    # Use different selectors based on chart type
    local pod_selector=""
    if [[ "$CHART_TYPE" == "official" ]]; then
        pod_selector="app.kubernetes.io/name=grafana"
    else
        pod_selector="app.kubernetes.io/name=grafana"
    fi
    
    local pod_name=$(kubectl_cmd get pods -n "$NAMESPACE" -l "$pod_selector" -o jsonpath='{.items[0].metadata.name}')
    
    if [[ -z "$pod_name" ]]; then
        add_result "Database Integration" "FAIL" "No Grafana pod found to check database integration" "kubectl_cmd get pods -n $NAMESPACE -l $pod_selector"
        return
    fi
    
    # Check health endpoint first (more reliable than log parsing)
    if command -v curl &> /dev/null; then
        local health_response=$(curl -s -w "%{http_code}" "$GRAFANA_URL/api/health" -o /tmp/health_response 2>/dev/null || echo "000")
        
        if [[ "$health_response" == "200" ]]; then
            local health_data=$(cat /tmp/health_response)
            if echo "$health_data" | grep -q '"database":"ok"'; then
                add_result "Database Integration" "PASS" "PostgreSQL connection established (health check)" "curl $GRAFANA_URL/api/health"
                return
            else
                add_result "Database Integration" "WARN" "Health endpoint responding but database may not be OK" "curl $GRAFANA_URL/api/health"
            fi
        else
            add_result "Database Integration" "SKIP" "curl not available, cannot test database connection" "Install curl"
        fi
        rm -f /tmp/health_response
    fi
    
    # Try to verify tables in PostgreSQL database
    if command -v psql &> /dev/null; then
        log "DEBUG" "Checking PostgreSQL tables..."
        local table_count=$(PGPASSWORD="$DB_PASSWORD" psql -h "$DB_HOST" -p "$DB_PORT" -U "$DB_USER" -d "$DB_NAME" -t -c "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = \"public\";" 2>/dev/null || echo "0")
        
        if [[ "$table_count" -gt 0 ]]; then
            add_result "Database Tables" "PASS" "Found $table_count tables in PostgreSQL database" "psql -h $DB_HOST -p $DB_PORT -U $DB_USER -d $DB_NAME -c '\\dt'"
        else
            add_result "Database Tables" "FAIL" "No tables found in PostgreSQL database" "Check database connection and permissions"
        fi
    else
        add_result "Database Tables" "SKIP" "psql not available, cannot verify tables" "Install PostgreSQL client"
    fi
}

# Function to verify health endpoints
verify_health_endpoints() {
    log "STEP" "Verifying health endpoints"
    
    # Test health endpoint
    if command -v curl &> /dev/null; then
        local health_response=$(curl -s -w "%{http_code}" -o /tmp/health_response "$GRAFANA_URL/api/health" || echo "000")
        
        if [[ "$health_response" == "200" ]]; then
            local health_data=$(cat /tmp/health_response)
            if echo "$health_data" | grep -q '"database":"ok"'; then
                add_result "Health Endpoint" "PASS" "Health endpoint responding, database OK" "curl $GRAFANA_URL/api/health"
            else
                add_result "Health Endpoint" "WARN" "Health endpoint responding but database may not be OK" "curl $GRAFANA_URL/api/health"
            fi
        else
            add_result "Health Endpoint" "FAIL" "Health endpoint not responding (HTTP $health_response)" "curl -v $GRAFANA_URL/api/health"
        fi
        rm -f /tmp/health_response
    else
        add_result "Health Endpoint" "SKIP" "curl not available, cannot test health endpoint" "Install curl"
    fi
}

# Function to verify web UI access
verify_web_access() {
    log "STEP" "Verifying web UI access"
    
    if command -v curl &> /dev/null; then
        local login_response=$(curl -s -w "%{http_code}" -o /tmp/login_response "$GRAFANA_URL/login" || echo "000")
        
        if [[ "$login_response" == "200" ]]; then
            if grep -q "Grafana" /tmp/login_response; then
                add_result "Web Access" "PASS" "Grafana login page accessible" "curl $GRAFANA_URL/login"
            else
                add_result "Web Access" "WARN" "Login page responding but may not be Grafana" "curl $GRAFANA_URL/login"
            fi
        else
            add_result "Web Access" "FAIL" "Login page not accessible (HTTP $login_response)" "curl -v $GRAFANA_URL/login"
        fi
        rm -f /tmp/login_response
    else
        add_result "Web Access" "SKIP" "curl not available, cannot test web access" "Install curl"
    fi
}

# Function to verify admin login
verify_admin_login() {
    log "STEP" "Verifying admin login"
    
    if command -v curl &> /dev/null; then
        # Get login page and extract CSRF token
        local login_page=$(curl -s -c /tmp/cookies "$GRAFANA_URL/login")
        local csrf_token=$(echo "$login_page" | grep -o 'csrf_token[^"]*"[^"]*' | sed 's/.*"\([^"]*\)".*/\1/' || echo "")
        
        if [[ -n "$csrf_token" ]]; then
            # Attempt login
            local login_response=$(curl -s -b /tmp/cookies -c /tmp/cookies -X POST \
                -d "user=${GRAFANA_ADMIN_USER:-admin}" \
                -d "password=${GRAFANA_ADMIN_PASSWORD}" \
                -d "csrf_token=$csrf_token" \
                "$GRAFANA_URL/login" -w "%{http_code}" -o /tmp/login_result)
            
            if [[ "$login_response" == "302" ]]; then
                add_result "Admin Login" "PASS" "Admin login successful" "Check web interface at $GRAFANA_URL"
            else
                add_result "Admin Login" "FAIL" "Admin login failed (HTTP $login_response)" "Verify admin credentials"
            fi
        else
            add_result "Admin Login" "WARN" "Could not extract CSRF token, login test skipped" "Manual login verification required"
        fi
        
        # Cleanup
        rm -f /tmp/cookies /tmp/login_result
    else
        add_result "Admin Login" "SKIP" "curl not available, cannot test admin login" "Install curl"
    fi
}

# Function to verify configuration consistency
verify_configuration() {
    log "STEP" "Verifying configuration consistency"
    
    # Check if Grafana is using correct configuration
    # Use different selectors based on chart type
    local pod_selector=""
    if [[ "$CHART_TYPE" == "official" ]]; then
        pod_selector="app.kubernetes.io/name=grafana"
    else
        pod_selector="app.kubernetes.io/name=grafana"
    fi
    
    local pod_name=$(kubectl_cmd get pods -n "$NAMESPACE" -l "$pod_selector" -o jsonpath='{.items[0].metadata.name}')
    
    if [[ -z "$pod_name" ]]; then
        add_result "Configuration" "FAIL" "No Grafana pod found to check configuration" "kubectl_cmd get pods -n $NAMESPACE -l $pod_selector"
        return
    fi
    
    # Check Grafana configuration file
    local config_check=$(kubectl_cmd exec -n "$NAMESPACE" "$pod_name" -- cat /etc/grafana/grafana.ini 2>/dev/null | grep -A 10 "\[database\]" || echo "")
    
    # Check for PostgreSQL configuration - more robust check
    if echo "$config_check" | grep -qiE "type\s*=\s*postgres|type\s*=\s*postgresql"; then
        # Additional check for host configuration
        if echo "$config_check" | grep -qiE "host\s*="; then
            add_result "Configuration" "PASS" "PostgreSQL database configured in grafana.ini" "kubectl_cmd exec -n $NAMESPACE $pod_name -- cat /etc/grafana/grafana.ini"
        else
            add_result "Configuration" "WARN" "PostgreSQL type configured but host may be missing" "kubectl_cmd exec -n $NAMESPACE $pod_name -- cat /etc/grafana/grafana.ini"
        fi
    else
        add_result "Configuration" "FAIL" "PostgreSQL not configured in grafana.ini" "Check database configuration in values file"
    fi
}

# =============================================================================
# REPORT GENERATION
# =============================================================================

# Function to generate verification report
generate_verification_report() {
    log "HEADER" "Generating Verification Report"
    
    local total_tests=${#VERIFICATION_RESULTS[@]}
    local passed_tests=0
    local failed_tests=0
    local warning_tests=0
    local skipped_tests=0
    
    # Count test results
    for result in "${VERIFICATION_RESULTS[@]}"; do
        local status=$(echo "$result" | cut -d'|' -f2)
        case "$status" in
            "PASS") passed_tests=$((passed_tests + 1)) ;;
            "FAIL") failed_tests=$((failed_tests + 1)) ;;
            "WARN") warning_tests=$((warning_tests + 1)) ;;
            "SKIP") skipped_tests=$((skipped_tests + 1)) ;;
        esac
    done
    
    # Generate report
    {
        echo "GRAFANA DEPLOYMENT VERIFICATION REPORT"
        echo "======================================="
        echo "Generated: $(date)"
        echo "Chart Type: $CHART_TYPE"
        echo "Namespace: $NAMESPACE"
        echo "Release Name: $HELM_RELEASE_NAME"
        echo "Grafana URL: $GRAFANA_URL"
        echo ""
        
        echo "VERIFICATION SUMMARY"
        echo "--------------------"
        echo "Total Tests: $total_tests"
        echo "Passed: $passed_tests ✅"
        echo "Failed: $failed_tests ❌"
        echo "Warnings: $warning_tests ⚠️"
        echo "Skipped: $skipped_tests ⏭️"
        echo ""
        
        if [[ $failed_tests -eq 0 ]]; then
            echo "OVERALL STATUS: SUCCESS ✅"
        else
            echo "OVERALL STATUS: FAILED ❌"
        fi
        echo ""
        
        echo "DETAILED RESULTS"
        echo "----------------"
        for result in "${VERIFICATION_RESULTS[@]}"; do
            local test_name=$(echo "$result" | cut -d'|' -f1)
            local status=$(echo "$result" | cut -d'|' -f2)
            local message=$(echo "$result" | cut -d'|' -f3)
            local details=$(echo "$result" | cut -d'|' -f4)
            
            case "$status" in
                "PASS") echo "✅ $test_name: $message" ;;
                "FAIL") echo "❌ $test_name: $message" ;;
                "WARN") echo "⚠️  $test_name: $message" ;;
                "SKIP") echo "⏭️  $test_name: $message" ;;
            esac
            
            if [[ -n "$details" ]]; then
                echo "   💡 Recommended action: $details"
            fi
            echo ""
        done
        
        echo "ACCESS INFORMATION"
        echo "------------------"
        echo "Grafana URL: $GRAFANA_URL"
        if [[ "$INGRESS_ENABLED" == "true" ]]; then
            echo "Ingress Host: $INGRESS_HOST"
            echo "Fallback URL: http://${NODE_IP}:${SERVICE_HTTP_NODEPORT}"
            echo "Note: Add '$NODE_IP $INGRESS_HOST' to /etc/hosts if needed"
        fi
        echo "Admin User: ${GRAFANA_ADMIN_USER:-admin}"
        echo "Admin Password: [REDACTED]"
        echo ""
        
        echo "TROUBLESHOOTING COMMANDS"
        echo "------------------------"
        echo "Check pod logs: kubectl_cmd logs -f deployment/$HELM_RELEASE_NAME -n $NAMESPACE"
        echo "Check pod events: kubectl_cmd describe pod -l app.kubernetes.io/name=grafana -n $NAMESPACE"
        echo "Check service: kubectl_cmd get service $HELM_RELEASE_NAME -n $NAMESPACE -o yaml"
        echo "Check ingress: kubectl_cmd get ingress $HELM_RELEASE_NAME -n $NAMESPACE -o yaml"
        echo "Check PVC: kubectl_cmd get pvc -n $NAMESPACE -l app.kubernetes.io/name=grafana"
        if [[ "$INGRESS_ENABLED" == "true" ]]; then
            echo "Check ingress controller: kubectl_cmd get pods -n ingress-nginx"
            echo "Check ingress classes: kubectl_cmd get ingressclass"
        fi
        echo ""
        
        if [[ $failed_tests -gt 0 ]]; then
            echo "RECOMMENDED ACTIONS"
            echo "--------------------"
            echo "1. Fix failed verification items"
            echo "2. Run cleanup script: ./scripts/cleanup.sh"
            echo "3. Redeploy: ./scripts/deploy.sh"
            echo "4. Re-run verification: ./scripts/verify.sh"
        else
            echo "NEXT STEPS"
            echo "----------"
            echo "1. Access Grafana at: $GRAFANA_URL"
            echo "2. Configure data sources"
            echo "3. Create dashboards"
            echo "4. Set up monitoring and alerts"
        fi
        
    } > "$VERIFICATION_REPORT"
    
    log "SUCCESS" "Verification report generated: $VERIFICATION_REPORT"
    
    # Display summary
    echo ""
    log "INFO" "📊 Verification Summary:"
    log "INFO" "   Total Tests: $total_tests"
    log "INFO" "   Passed: $passed_tests ✅"
    log "INFO" "   Failed: $failed_tests ❌"
    log "INFO" "   Warnings: $warning_tests ⚠️"
    log "INFO" "   Skipped: $skipped_tests ⏭️"
    echo ""
    
    if [[ $failed_tests -eq 0 ]]; then
        log "SUCCESS" "🎉 All critical tests passed! Grafana deployment is working correctly."
    else
        log "ERROR" "❌ $failed_tests test(s) failed. Please review the report and fix the issues."
    fi
    
    echo ""
    log "INFO" "📋 Full report: $VERIFICATION_REPORT"
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================

# Function to display usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Verify Grafana deployment by checking all critical components.

OPTIONS:
    -n, --namespace NAME      Kubernetes namespace [default: grafana]
    -r, --release-name NAME   Helm release name [default: grafana]
    -t, --chart-type TYPE     Chart type used (official) [default: official]
    -u, --url URL             Grafana URL [default: http://10.110.40.193:30030]
    -q, --quick               Run quick verification (skip web tests)
    -v, --verbose             Enable verbose logging
    -h, --help                Show this help message

EXAMPLES:
    $0                                    # Run full verification
    $0 -q                                 # Run quick verification
    $0 -n monitoring -r grafana-prod     # Verify specific deployment
    $0 -t official                       # Verify official chart deployment

ENVIRONMENT VARIABLES:
    GRAFANA_NAMESPACE                    Kubernetes namespace
    HELM_RELEASE_NAME                    Helm release name
    CHART_TYPE                           Chart type (official)
    GRAFANA_URL                          Grafana URL
    INGRESS_CLASS                        Ingress class name (default: public for MicroK8s, nginx otherwise)
    INGRESS_HOST                         Ingress hostname
    INGRESS_ENABLED                      Enable ingress (true/false)
    DEBUG_MODE                           Enable debug mode (true/false)

EOF
}

# Function to parse command line arguments
parse_arguments() {
    local quick_mode=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -n|--namespace)
                NAMESPACE="$2"
                shift 2
                ;;
            -r|--release-name)
                HELM_RELEASE_NAME="$2"
                shift 2
                ;;
            -t|--chart-type)
                CHART_TYPE="$2"
                shift 2
                ;;
            -u|--url)
                GRAFANA_URL="$2"
                shift 2
                ;;
            -q|--quick)
                quick_mode=true
                shift
                ;;
            -v|--verbose)
                export DEBUG_MODE="true"
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                log_and_exit "ERROR" "Unknown option: $1"
                ;;
        esac
    done
    
    # Set quick mode flag
    export QUICK_MODE="$quick_mode"
}

# Main verification function
main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Initialize script
    init_script
    
    # Start verification process
    log "HEADER" "Starting Grafana Deployment Verification"
    log "INFO" "Namespace: $NAMESPACE"
    log "INFO" "Release Name: $HELM_RELEASE_NAME"
    log "INFO" "Chart Type: $CHART_TYPE"
    log "INFO" "Grafana URL: $GRAFANA_URL"
    log "INFO" "Quick Mode: ${QUICK_MODE:-false}"
    
    # Run verification tests
    verify_namespace
    verify_helm_release
    verify_pods
    verify_service
    verify_ingress
    verify_ingress_controller
    verify_persistence
    verify_resources
    verify_database_integration
    verify_configuration
    
    # Run web tests only if not in quick mode
    if [[ "${QUICK_MODE:-false}" != "true" ]]; then
        verify_health_endpoints
        verify_web_access
        verify_admin_login
    else
        add_result "Web Tests" "SKIP" "Web tests skipped in quick mode" "Run without -q flag to enable web tests"
    fi
    
    # Generate report
    generate_verification_report
    
    # Exit with appropriate code
    local failed_tests=0
    for result in "${VERIFICATION_RESULTS[@]}"; do
        local status=$(echo "$result" | cut -d'|' -f2)
        if [[ "$status" == "FAIL" ]]; then
            failed_tests=$((failed_tests + 1))
        fi
    done
    
    if [[ $failed_tests -gt 0 ]]; then
        exit 1
    else
        exit 0
    fi
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

# Run main function with all arguments
main "$@"
