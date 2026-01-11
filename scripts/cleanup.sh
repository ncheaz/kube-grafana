#!/bin/bash

# =============================================================================
# GRAFANA DEPLOYMENT CLEANUP SCRIPT
# =============================================================================
# This script removes Grafana deployment and optionally cleans up related resources

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

# Cleanup configuration
CLEANUP_REPORT="$PROJECT_ROOT/cleanup-report-$(get_timestamp).txt"
BACKUP_DIR="$PROJECT_ROOT/backups"

# Deployment configuration
NAMESPACE="${GRAFANA_NAMESPACE:-grafana}"
HELM_RELEASE_NAME="${HELM_RELEASE_NAME:-grafana}"

# Cleanup options
REMOVE_PVC="${REMOVE_PVC:-false}"
REMOVE_SECRETS="${REMOVE_SECRETS:-false}"
REMOVE_CONFIGMAPS="${REMOVE_CONFIGMAPS:-false}"
REMOVE_RBAC="${REMOVE_RBAC:-true}"
REMOVE_NAMESPACE="${REMOVE_NAMESPACE:-false}"
CREATE_BACKUP="${CREATE_BACKUP:-true}"

# =============================================================================
# CLEANUP FUNCTIONS
# =============================================================================

# Function to create backup before cleanup
create_cleanup_backup() {
    log "HEADER" "Creating Cleanup Backup"
    
    if [[ "$CREATE_BACKUP" != "true" ]]; then
        log "INFO" "Backup creation disabled"
        return 0
    fi
    
    ensure_dir "$BACKUP_DIR"
    local backup_timestamp=$(get_timestamp)
    local backup_dir="$BACKUP_DIR/cleanup-backup-$backup_timestamp"
    
    ensure_dir "$backup_dir"
    
    # Backup Helm values files
    log "STEP" "Backing up Helm values files"
    cp -r "$PROJECT_ROOT/helm-values" "$backup_dir/" 2>/dev/null || true
    
    # Backup environment file
    log "STEP" "Backing up environment configuration"
    cp "$PROJECT_ROOT/.env" "$backup_dir/" 2>/dev/null || true
    
    # Backup current deployment configuration
    if helm_release_exists "$HELM_RELEASE_NAME" "$NAMESPACE"; then
        log "STEP" "Backing up current deployment configuration"
        helm_cmd get values "$HELM_RELEASE_NAME" -n "$NAMESPACE" > "$backup_dir/current-values.yaml" 2>/dev/null || true
        helm_cmd status "$HELM_RELEASE_NAME" -n "$NAMESPACE" > "$backup_dir/deployment-status.txt" 2>/dev/null || true
    fi
    
    # Backup Kubernetes resources
    log "STEP" "Backing up Kubernetes resources"
    
    # Backup services
    kubectl_cmd get service -n "$NAMESPACE" -o yaml > "$backup_dir/services.yaml" 2>/dev/null || true
    
    # Backup PVCs
    kubectl_cmd get pvc -n "$NAMESPACE" -o yaml > "$backup_dir/pvcs.yaml" 2>/dev/null || true
    
    # Backup ConfigMaps
    kubectl_cmd get configmap -n "$NAMESPACE" -o yaml > "$backup_dir/configmaps.yaml" 2>/dev/null || true
    
    # Backup Secrets
    kubectl_cmd get secret -n "$NAMESPACE" -o yaml > "$backup_dir/secrets.yaml" 2>/dev/null || true
    
    # Create backup info file
    {
        echo "GRAFANA DEPLOYMENT CLEANUP BACKUP"
        echo "==============================="
        echo "Created: $(date)"
        echo "Namespace: $NAMESPACE"
        echo "Release Name: $HELM_RELEASE_NAME"
        echo ""
        echo "BACKUP CONTENTS:"
        echo "- Helm values files"
        echo "- Environment configuration"
        echo "- Current deployment configuration (if exists)"
        echo "- Kubernetes resources (services, PVCs, ConfigMaps, secrets)"
        echo ""
        echo "RESTORE INSTRUCTIONS:"
        echo "1. Review backup contents"
        echo "2. Restore using: ./scripts/deploy.sh"
        echo "3. Apply custom configurations if needed"
    } > "$backup_dir/README.txt"
    
    log "SUCCESS" "Backup created: $backup_dir"
    echo "$backup_dir" > "$BACKUP_DIR/latest-backup.txt"
}

# Function to uninstall Helm release
uninstall_helm_release() {
    log "HEADER" "Uninstalling Helm Release"
    
    if ! helm_release_exists "$HELM_RELEASE_NAME" "$NAMESPACE"; then
        log "INFO" "Helm release $HELM_RELEASE_NAME does not exist in namespace $NAMESPACE"
        return 0
    fi
    
    log "STEP" "Getting release information"
    local release_status=$(get_helm_release_status "$HELM_RELEASE_NAME" "$NAMESPACE")
    log "INFO" "Current release status: $release_status"
    
    log "STEP" "Uninstalling Helm release $HELM_RELEASE_NAME"
    if helm_cmd uninstall "$HELM_RELEASE_NAME" -n "$NAMESPACE"; then
        log "SUCCESS" "Helm release $HELM_RELEASE_NAME uninstalled successfully"
    else
        log_and_exit "ERROR" "Failed to uninstall Helm release $HELM_RELEASE_NAME"
    fi
    
    # Wait for resources to be removed
    log "STEP" "Waiting for resources to be removed"
    local timeout=60
    local elapsed=0
    
    while [[ $elapsed -lt $timeout ]]; do
        if ! helm_release_exists "$HELM_RELEASE_NAME" "$NAMESPACE"; then
            log "SUCCESS" "Helm release completely removed"
            break
        fi
        
        sleep 5
        elapsed=$((elapsed + 5))
        log "DEBUG" "Waiting for release removal... (${elapsed}s elapsed)"
    done
    
    if helm_release_exists "$HELM_RELEASE_NAME" "$NAMESPACE"; then
        log "WARN" "Helm release still exists after timeout, proceeding with manual cleanup"
    fi
}

# Function to cleanup remaining resources
cleanup_remaining_resources() {
    log "HEADER" "Cleaning Up Remaining Resources"
    
    # Clean up pods
    log "STEP" "Cleaning up remaining pods"
    local pods=$(kubectl_cmd get pods -n "$NAMESPACE" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$pods" ]]; then
        log "INFO" "Deleting remaining pods: $pods"
        kubectl_cmd delete pods -n "$NAMESPACE" -l app.kubernetes.io/name=grafana --ignore-not-found=true
    else
        log "INFO" "No remaining pods found"
    fi
    
    # Clean up services
    log "STEP" "Cleaning up services"
    local services=$(kubectl_cmd get service -n "$NAMESPACE" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$services" ]]; then
        log "INFO" "Deleting services: $services"
        kubectl_cmd delete service -n "$NAMESPACE" -l app.kubernetes.io/name=grafana --ignore-not-found=true
    else
        log "INFO" "No services found"
    fi
    
    # Clean up ConfigMaps
    if [[ "$REMOVE_CONFIGMAPS" == "true" ]]; then
        log "STEP" "Cleaning up ConfigMaps"
        local configmaps=$(kubectl_cmd get configmap -n "$NAMESPACE" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        
        if [[ -n "$configmaps" ]]; then
            log "INFO" "Deleting ConfigMaps: $configmaps"
            kubectl_cmd delete configmap -n "$NAMESPACE" -l app.kubernetes.io/name=grafana --ignore-not-found=true
        else
            log "INFO" "No ConfigMaps found"
        fi
    else
        log "INFO" "ConfigMap cleanup disabled"
    fi
    
    # Clean up Secrets
    if [[ "$REMOVE_SECRETS" == "true" ]]; then
        log "STEP" "Cleaning up Secrets"
        local secrets=$(kubectl_cmd get secret -n "$NAMESPACE" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        
        if [[ -n "$secrets" ]]; then
            log "INFO" "Deleting secrets: $secrets"
            kubectl_cmd delete secret -n "$NAMESPACE" -l app.kubernetes.io/name=grafana --ignore-not-found=true
        else
            log "INFO" "No secrets found"
        fi
    else
        log "INFO" "Secret cleanup disabled"
    fi
    
    # Clean up PVCs
    if [[ "$REMOVE_PVC" == "true" ]]; then
        log "STEP" "Cleaning up PVCs"
        local pvcs=$(kubectl_cmd get pvc -n "$NAMESPACE" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
        
        if [[ -n "$pvcs" ]]; then
            log "WARN" "Deleting PVCs (this will delete all data): $pvcs"
            kubectl_cmd delete pvc -n "$NAMESPACE" -l app.kubernetes.io/name=grafana --ignore-not-found=true
        else
            log "INFO" "No PVCs found"
        fi
    else
        log "INFO" "PVC cleanup disabled (data will be preserved)"
    fi
}

# Function to cleanup RBAC resources
cleanup_rbac_resources() {
    if [[ "$REMOVE_RBAC" != "true" ]]; then
        log "INFO" "RBAC cleanup disabled"
        return 0
    fi
    
    log "HEADER" "Cleaning Up RBAC Resources"
    
    # Clean up ServiceAccounts
    log "STEP" "Cleaning up ServiceAccounts"
    local serviceaccounts=$(kubectl_cmd get serviceaccount -n "$NAMESPACE" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$serviceaccounts" ]]; then
        log "INFO" "Deleting ServiceAccounts: $serviceaccounts"
        kubectl_cmd delete serviceaccount -n "$NAMESPACE" -l app.kubernetes.io/name=grafana --ignore-not-found=true
    else
        log "INFO" "No ServiceAccounts found"
    fi
    
    # Clean up Roles
    log "STEP" "Cleaning up Roles"
    local roles=$(kubectl_cmd get role -n "$NAMESPACE" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$roles" ]]; then
        log "INFO" "Deleting Roles: $roles"
        kubectl_cmd delete role -n "$NAMESPACE" -l app.kubernetes.io/name=grafana --ignore-not-found=true
    else
        log "INFO" "No Roles found"
    fi
    
    # Clean up RoleBindings
    log "STEP" "Cleaning up RoleBindings"
    local rolebindings=$(kubectl_cmd get rolebinding -n "$NAMESPACE" -l app.kubernetes.io/name=grafana -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")
    
    if [[ -n "$rolebindings" ]]; then
        log "INFO" "Deleting RoleBindings: $rolebindings"
        kubectl_cmd delete rolebinding -n "$NAMESPACE" -l app.kubernetes.io/name=grafana --ignore-not-found=true
    else
        log "INFO" "No RoleBindings found"
    fi
}

# Function to cleanup namespace
cleanup_namespace() {
    if [[ "$REMOVE_NAMESPACE" != "true" ]]; then
        log "INFO" "Namespace cleanup disabled"
        return 0
    fi
    
    log "HEADER" "Cleaning Up Namespace"
    
    if ! namespace_exists "$NAMESPACE"; then
        log "INFO" "Namespace $NAMESPACE does not exist"
        return 0
    fi
    
    # Check if namespace has other resources
    local resource_count=$(kubectl_cmd api-resources --verbs=list --namespaced -o name | xargs -I {} kubectl_cmd get {} -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l || echo "0")
    
    if [[ $resource_count -gt 0 ]]; then
        log "WARN" "Namespace $NAMESPACE still contains $resource_count resources"
        log "INFO" "Force deleting namespace (this will delete all resources in the namespace)"
        
        if kubectl_cmd delete namespace "$NAMESPACE" --ignore-not-found=true; then
            log "SUCCESS" "Namespace $NAMESPACE deleted successfully"
        else
            log_and_exit "ERROR" "Failed to delete namespace $NAMESPACE"
        fi
    else
        log "INFO" "Namespace is empty, deleting..."
        kubectl_cmd delete namespace "$NAMESPACE" --ignore-not-found=true
        log "SUCCESS" "Namespace $NAMESPACE deleted successfully"
    fi
}

# Function to cleanup local files
cleanup_local_files() {
    log "HEADER" "Cleaning Up Local Files"
    
    # Clean up temporary files
    log "STEP" "Cleaning up temporary files"
    if [[ -d "$PROJECT_ROOT/temp" ]]; then
        rm -rf "$PROJECT_ROOT/temp"
        log "INFO" "Temporary files cleaned up"
    fi
    
    # Clean up old logs (keep last 5)
    log "STEP" "Cleaning up old log files"
    find "$PROJECT_ROOT" -name "*.log" -type f | sort -r | tail -n +6 | xargs -r rm -f
    log "INFO" "Old log files cleaned up"
    
    # Clean up old reports (keep last 5)
    log "STEP" "Cleaning up old report files"
    find "$PROJECT_ROOT" -name "*-report-*.txt" -type f | sort -r | tail -n +6 | xargs -r rm -f
    log "INFO" "Old report files cleaned up"
}

# Function to generate cleanup report
generate_cleanup_report() {
    log "HEADER" "Generating Cleanup Report"
    
    {
        echo "GRAFANA DEPLOYMENT CLEANUP REPORT"
        echo "================================"
        echo "Generated: $(date)"
        echo "Namespace: $NAMESPACE"
        echo "Release Name: $HELM_RELEASE_NAME"
        echo ""
        
        echo "CLEANUP OPTIONS"
        echo "---------------"
        echo "Remove PVCs: $REMOVE_PVC"
        echo "Remove Secrets: $REMOVE_SECRETS"
        echo "Remove ConfigMaps: $REMOVE_CONFIGMAPS"
        echo "Remove RBAC: $REMOVE_RBAC"
        echo "Remove Namespace: $REMOVE_NAMESPACE"
        echo "Create Backup: $CREATE_BACKUP"
        echo ""
        
        echo "CLEANUP ACTIONS"
        echo "---------------"
        echo "✓ Helm release uninstalled"
        echo "✓ Remaining resources cleaned up"
        echo "✓ RBAC resources cleaned up (if enabled)"
        echo "✓ Namespace cleaned up (if enabled)"
        echo "✓ Local files cleaned up"
        echo ""
        
        echo "BACKUP INFORMATION"
        echo "------------------"
        if [[ "$CREATE_BACKUP" == "true" && -f "$BACKUP_DIR/latest-backup.txt" ]]; then
            local backup_location=$(cat "$BACKUP_DIR/latest-backup.txt")
            echo "Backup created: $backup_location"
            echo "Backup contents:"
            echo "- Helm values files"
            echo "- Environment configuration"
            echo "- Deployment configuration"
            echo "- Kubernetes resources"
        else
            echo "No backup created"
        fi
        echo ""
        
        echo "REDEPLOYMENT INSTRUCTIONS"
        echo "------------------------"
        echo "1. Review backup (if created)"
        echo "2. Run pre-deployment tests: ./tests/pre-deploy.sh"
        echo "3. Deploy Grafana: ./scripts/deploy.sh"
        echo "4. Verify deployment: ./scripts/verify.sh"
        echo ""
        
        echo "TROUBLESHOOTING"
        echo "---------------"
        echo "If resources remain after cleanup:"
        echo "1. Check namespace: kubectl get namespace $NAMESPACE"
        echo "2. Check resources: kubectl get all -n $NAMESPACE"
        echo "3. Force cleanup: kubectl delete namespace $NAMESPACE --grace-period=0 --force"
        
    } > "$CLEANUP_REPORT"
    
    log "SUCCESS" "Cleanup report generated: $CLEANUP_REPORT"
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================

# Function to display usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Remove Grafana deployment and optionally clean up related resources.

OPTIONS:
    -n, --namespace NAME      Kubernetes namespace [default: grafana]
    -r, --release-name NAME   Helm release name [default: grafana]
    --remove-pvc              Remove PVCs (WARNING: deletes all data)
    --remove-secrets          Remove secrets
    --remove-configmaps        Remove ConfigMaps
    --remove-rbac             Remove RBAC resources [default: true]
    --remove-namespace        Remove entire namespace
    --no-backup               Skip backup creation
    --dry-run                 Show what would be removed without actually removing
    -v, --verbose             Enable verbose logging
    -h, --help                Show this help message

EXAMPLES:
    $0                                    # Basic cleanup (keep data and namespace)
    $0 --remove-pvc                       # Remove everything including data
    $0 --remove-namespace                  # Remove entire namespace
    $0 --dry-run                          # Show what would be removed

ENVIRONMENT VARIABLES:
    GRAFANA_NAMESPACE                    Kubernetes namespace
    HELM_RELEASE_NAME                    Helm release name
    REMOVE_PVC                           Remove PVCs (true/false)
    REMOVE_SECRETS                       Remove secrets (true/false)
    REMOVE_CONFIGMAPS                    Remove ConfigMaps (true/false)
    REMOVE_RBAC                          Remove RBAC (true/false)
    REMOVE_NAMESPACE                     Remove namespace (true/false)
    CREATE_BACKUP                        Create backup (true/false)

EOF
}

# Function to parse command line arguments
parse_arguments() {
    local dry_run=false
    
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
            --remove-pvc)
                export REMOVE_PVC="true"
                shift
                ;;
            --remove-secrets)
                export REMOVE_SECRETS="true"
                shift
                ;;
            --remove-configmaps)
                export REMOVE_CONFIGMAPS="true"
                shift
                ;;
            --remove-rbac)
                export REMOVE_RBAC="true"
                shift
                ;;
            --remove-namespace)
                export REMOVE_NAMESPACE="true"
                shift
                ;;
            --no-backup)
                export CREATE_BACKUP="false"
                shift
                ;;
            --dry-run)
                dry_run=true
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
    
    # Set dry run flag
    export DRY_RUN="$dry_run"
}

# Main cleanup function
main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Initialize script
    init_script
    
    # Display cleanup configuration
    log "HEADER" "Starting Grafana Deployment Cleanup"
    log "INFO" "Namespace: $NAMESPACE"
    log "INFO" "Release Name: $HELM_RELEASE_NAME"
    log "INFO" "Remove PVCs: $REMOVE_PVC"
    log "INFO" "Remove Secrets: $REMOVE_SECRETS"
    log "INFO" "Remove ConfigMaps: $REMOVE_CONFIGMAPS"
    log "INFO" "Remove RBAC: $REMOVE_RBAC"
    log "INFO" "Remove Namespace: $REMOVE_NAMESPACE"
    log "INFO" "Create Backup: $CREATE_BACKUP"
    log "INFO" "Dry Run: ${DRY_RUN:-false}"
    
    # Warning for destructive operations
    if [[ "$REMOVE_PVC" == "true" || "$REMOVE_NAMESPACE" == "true" ]]; then
        log "WARN" "⚠️  WARNING: This operation will delete data!"
        log "WARN" "⚠️  You have 10 seconds to cancel (Ctrl+C)..."
        sleep 10
    fi
    
    # Perform cleanup steps
    if [[ "${DRY_RUN:-false}" != "true" ]]; then
        create_cleanup_backup
        uninstall_helm_release
        cleanup_remaining_resources
        cleanup_rbac_resources
        cleanup_namespace
        cleanup_local_files
        generate_cleanup_report
        
        log "SUCCESS" "🧹 Grafana deployment cleanup completed successfully!"
    else
        log "INFO" "DRY RUN: The following would be cleaned up:"
        log "INFO" "- Helm release: $HELM_RELEASE_NAME in namespace $NAMESPACE"
        log "INFO" "- Pods, services, and other resources in namespace $NAMESPACE"
        [[ "$REMOVE_PVC" == "true" ]] && log "INFO" "- PVCs (data would be deleted)"
        [[ "$REMOVE_SECRETS" == "true" ]] && log "INFO" "- Secrets"
        [[ "$REMOVE_CONFIGMAPS" == "true" ]] && log "INFO" "- ConfigMaps"
        [[ "$REMOVE_RBAC" == "true" ]] && log "INFO" "- RBAC resources"
        [[ "$REMOVE_NAMESPACE" == "true" ]] && log "INFO" "- Namespace $NAMESPACE"
        [[ "$CREATE_BACKUP" == "true" ]] && log "INFO" "- Backup would be created"
        log "INFO" "Run without --dry-run to perform actual cleanup"
    fi
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

# Run main function with all arguments
main "$@"