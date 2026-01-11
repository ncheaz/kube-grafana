#!/bin/bash

# =============================================================================
# INGRESS CONFIGURATION TEST SCRIPT
# =============================================================================
# This script tests the ingress configuration for Grafana deployment

set -euo pipefail

# Script directory and paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source utility functions
source "$SCRIPT_DIR/utils.sh"

# =============================================================================
# GLOBAL VARIABLES
# =============================================================================

# Test configuration
export TEST_MODE="true"
NAMESPACE="${GRAFANA_NAMESPACE:-grafana}"
HELM_RELEASE_NAME="${HELM_RELEASE_NAME:-grafana}"
INGRESS_HOST="${INGRESS_HOST:-grafana.local}"
NODE_IP="${NODE_IP:-10.110.40.193}"

# =============================================================================
# TEST FUNCTIONS
# =============================================================================

# Function to test ingress YAML syntax (wrapper for utils function)
test_ingress_yaml() {
    log "STEP" "Testing Ingress YAML syntax"
    test_ingress_yaml "$PROJECT_ROOT"
}

# Function to test ingress template rendering (wrapper for utils function)
test_ingress_template() {
    log "STEP" "Testing Ingress template rendering"
    test_ingress_template "$PROJECT_ROOT" "$NAMESPACE" "$HELM_RELEASE_NAME"
}

# Function to test ingress controller availability (wrapper for utils function)
test_ingress_controller() {
    log "STEP" "Testing Ingress Controller availability"
    
    # Check for NGINX ingress controller specifically for this test
    if kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx &>/dev/null; then
        local nginx_pods=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --no-headers | wc -l)
        local nginx_ready=$(kubectl get pods -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --no-headers | grep -c "Running" || echo "0")
        
        if [[ $nginx_ready -gt 0 ]]; then
            log "SUCCESS" "NGINX Ingress Controller: $nginx_ready/$nginx_pods pods running"
            return 0
        else
            log "WARN" "NGINX Ingress Controller found but no pods running"
            return 1
        fi
    fi
    
    # Use the consolidated function for general ingress controller checking
    check_ingress_controller "${INGRESS_CLASS:-public}"
}

# Function to test DNS resolution
test_dns_resolution() {
    log "STEP" "Testing DNS resolution for $INGRESS_HOST"
    
    if command -v nslookup &> /dev/null; then
        if nslookup "$INGRESS_HOST" &>/dev/null; then
            log "SUCCESS" "DNS resolution successful for $INGRESS_HOST"
            return 0
        else
            log "WARN" "DNS resolution failed for $INGRESS_HOST"
            log "INFO" "Add '$NODE_IP $INGRESS_HOST' to /etc/hosts"
            return 1
        fi
    elif command -v dig &> /dev/null; then
        if dig "$INGRESS_HOST" &>/dev/null; then
            log "SUCCESS" "DNS resolution successful for $INGRESS_HOST"
            return 0
        else
            log "WARN" "DNS resolution failed for $INGRESS_HOST"
            log "INFO" "Add '$NODE_IP $INGRESS_HOST' to /etc/hosts"
            return 1
        fi
    else
        log "INFO" "nslookup/dig not available, skipping DNS test"
        return 0
    fi
}

# Function to test HTTP connectivity to ingress
test_http_connectivity() {
    log "STEP" "Testing HTTP connectivity to $INGRESS_HOST"
    
    if command -v curl &> /dev/null; then
        local http_code=$(curl -s -w "%{http_code}" -o /tmp/ingress_test "http://$INGRESS_HOST" || echo "000")
        
        case "$http_code" in
            200|302)
                log "SUCCESS" "HTTP connectivity successful (HTTP $http_code)"
                return 0
                ;;
            404)
                log "WARN" "HTTP connectivity works but returns 404 (ingress may need adjustment)"
                return 1
                ;;
            000)
                log "ERROR" "HTTP connectivity failed"
                return 1
                ;;
            *)
                log "WARN" "HTTP connectivity returned unexpected code: $http_code"
                return 1
                ;;
        esac
        
        rm -f /tmp/ingress_test
    else
        log "INFO" "curl not available, skipping HTTP connectivity test"
        return 0
    fi
}

# Function to test ingress resource creation
test_ingress_creation() {
    log "STEP" "Testing Ingress resource creation"
    
    # Check if ingress would be created with current configuration
    local values_file="$PROJECT_ROOT/helm-values/official-grafana.yaml"
    local chart_name="grafana/grafana"
    
    # Render the ingress template
    local ingress_yaml=$(helm template "$HELM_RELEASE_NAME" "$chart_name" \
        --namespace "$NAMESPACE" \
        --values "$values_file" \
        --set ingress.enabled="true" \
        --show-only templates/ingress.yaml 2>/dev/null || echo "")
    
    if [[ -n "$ingress_yaml" ]]; then
        log "SUCCESS" "Ingress resource would be created"
        
        # Validate key ingress fields
        if echo "$ingress_yaml" | grep -q "ingressClassName: public"; then
            log "INFO" "✓ Ingress class set to public"
        else
            log "WARN" "Ingress class may not be set correctly"
        fi
        
        if echo "$ingress_yaml" | grep -q "host: $INGRESS_HOST"; then
            log "INFO" "✓ Ingress host set to $INGRESS_HOST"
        else
            log "WARN" "Ingress host may not be set correctly"
        fi
        
        return 0
    else
        log "ERROR" "Ingress resource would not be created"
        return 1
    fi
}

# Function to generate test report
generate_test_report() {
    local total_tests=$1
    local passed_tests=$2
    local failed_tests=$3
    
    echo ""
    log "HEADER" "Ingress Test Summary"
    echo "================================"
    echo "Total Tests: $total_tests"
    echo "Passed: $passed_tests ✅"
    echo "Failed: $failed_tests ❌"
    echo ""
    
    if [[ $failed_tests -eq 0 ]]; then
        log "SUCCESS" "🎉 All ingress tests passed! Configuration is ready."
        echo ""
        echo "Next steps:"
        echo "1. Deploy with: ./scripts/deploy-with-ingress.sh"
        echo "2. Verify with: ./scripts/verify.sh"
        echo "3. Add '$NODE_IP $INGRESS_HOST' to /etc/hosts if needed"
    else
        log "ERROR" "❌ $failed_tests test(s) failed. Please fix issues before deployment."
        echo ""
        echo "Common fixes:"
        echo "1. Install ingress controller: kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/cloud/deploy.yaml"
        echo "2. For MicroK8S: microk8s enable ingress"
        echo "3. Add '$NODE_IP $INGRESS_HOST' to /etc/hosts"
    fi
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================

# Function to display usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Test ingress configuration for Grafana deployment.

OPTIONS:
    -h, --help                Show this help message
    -q, --quick               Run quick tests only
    -v, --verbose             Enable verbose logging

EXAMPLES:
    $0                        # Run all tests
    $0 -q                     # Run quick tests only
    $0 -v                     # Run with verbose logging

ENVIRONMENT VARIABLES:
    GRAFANA_NAMESPACE         Kubernetes namespace [default: grafana]
    HELM_RELEASE_NAME         Helm release name [default: grafana]
    INGRESS_HOST              Ingress hostname [default: grafana.local]
    NODE_IP                   Cluster node IP [default: 10.110.40.193]

EOF
}

# Function to parse command line arguments
parse_arguments() {
    local quick_mode=false
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            -h|--help)
                usage
                exit 0
                ;;
            -q|--quick)
                quick_mode=true
                shift
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
    
    export QUICK_MODE="$quick_mode"
}

# Main test function
main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Initialize script
    init_script
    
    # Start testing
    log "HEADER" "Starting Ingress Configuration Tests"
    log "INFO" "Namespace: $NAMESPACE"
    log "INFO" "Release Name: $HELM_RELEASE_NAME"
    log "INFO" "Ingress Host: $INGRESS_HOST"
    log "INFO" "Node IP: $NODE_IP"
    log "INFO" "Quick Mode: ${QUICK_MODE:-false}"
    
    local total_tests=0
    local passed_tests=0
    local failed_tests=0
    
    # Run tests
    if test_ingress_yaml; then
        ((passed_tests++))
    else
        ((failed_tests++))
    fi
    ((total_tests++))
    
    if test_ingress_template; then
        ((passed_tests++))
    else
        ((failed_tests++))
    fi
    ((total_tests++))
    
    if test_ingress_controller; then
        ((passed_tests++))
    else
        ((failed_tests++))
    fi
    ((total_tests++))
    
    if test_ingress_creation; then
        ((passed_tests++))
    else
        ((failed_tests++))
    fi
    ((total_tests++))
    
    # Run additional tests only if not in quick mode
    if [[ "${QUICK_MODE:-false}" != "true" ]]; then
        if test_dns_resolution; then
            ((passed_tests++))
        else
            ((failed_tests++))
        fi
        ((total_tests++))
        
        if test_http_connectivity; then
            ((passed_tests++))
        else
            ((failed_tests++))
        fi
        ((total_tests++))
    fi
    
    # Generate report
    generate_test_report "$total_tests" "$passed_tests" "$failed_tests"
    
    # Exit with appropriate code
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