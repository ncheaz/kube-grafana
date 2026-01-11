#!/bin/bash

# =============================================================================
# GRAFANA DATABASE SCHEMA DELETION SCRIPT
# =============================================================================
# This script deletes all Grafana tables from the PostgreSQL database
# WARNING: This will permanently delete all Grafana data!
# Use with caution!

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

# =============================================================================
# CONFIRMATION FUNCTION
# =============================================================================

# Function to confirm destructive action
confirm_deletion() {
    local db_name="${1:-grafana}"
    
    echo ""
    echo "⚠️  WARNING: This will permanently delete ALL Grafana data!"
    echo "⚠️  Database: $db_name"
    echo "⚠️  This action cannot be undone!"
    echo ""
    
    read -p "Are you sure you want to delete the Grafana schema? (yes/no): " confirmation
    
    if [[ "$confirmation" != "yes" ]]; then
        log "INFO" "Schema deletion cancelled"
        exit 0
    fi
}

# =============================================================================
# SCHEMA DELETION FUNCTION
# =============================================================================

# Function to delete Grafana schema
delete_grafana_schema() {
    local db_name="${1:-grafana}"
    local db_user="${2:-grafana}"
    local db_password="${3:-grafana_password123}"
    local postgres_namespace="${4:-postgres}"
    local postgres_pod="${5:-postgres-postgresql-0}"
    local postgres_superuser="${6:-postgres}"
    local postgres_password="${7:-changeme123}"
    
    log "HEADER" "Deleting Grafana Schema"
    log "INFO" "Database: $db_name"
    log "INFO" "User: $db_user"
    log "INFO" "Pod: $postgres_pod (namespace: $postgres_namespace)"
    echo ""
    
    # Check if PostgreSQL pod is running
    log "STEP" "Checking PostgreSQL pod status"
    if ! kubectl_cmd get pod "$postgres_pod" -n "$postgres_namespace" &>/dev/null; then
        log_and_exit "ERROR" "PostgreSQL pod '$postgres_pod' not found in namespace '$postgres_namespace'"
    fi
    
    local pod_status=$(kubectl_cmd get pod "$postgres_pod" -n "$postgres_namespace" -o jsonpath='{.status.phase}')
    if [[ "$pod_status" != "Running" ]]; then
        log_and_exit "ERROR" "PostgreSQL pod is not running (status: $pod_status)"
    fi
    log "SUCCESS" "PostgreSQL pod is running"
    
    # Get list of all Grafana tables
    log "STEP" "Retrieving list of Grafana tables"
    local tables=$(kubectl_cmd exec -n "$postgres_namespace" "$postgres_pod" -- bash -c "PGPASSWORD=$db_password psql -U $db_user -d $db_name -t -c \"SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;\"")
    
    if [[ -z "$tables" ]]; then
        log "WARN" "No tables found in database '$db_name'"
        log "INFO" "Schema is already empty"
        return 0
    fi
    
    local table_count=$(echo "$tables" | wc -l)
    log "INFO" "Found $table_count tables to delete"
    echo ""
    
    # Display list of tables to be deleted
    log "INFO" "Tables to be deleted:"
    echo "$tables" | while read -r table; do
        echo "  - $table"
    done
    echo ""
    
    # Drop and recreate the entire database - this is the most reliable method
    log "STEP" "Dropping and recreating Grafana database"
    
    # Drop and recreate the entire database to ensure all tables are removed
    # This avoids issues with schema-level operations and ensures clean state
    # Note: We must use the postgres superuser credentials, not the grafana user credentials
    # Note: DROP DATABASE cannot run inside a transaction block, so we execute commands separately
    
    # First, disconnect all active connections to the database
    log "INFO" "Terminating active connections to database '$db_name'"
    kubectl_cmd exec -n "$postgres_namespace" "$postgres_pod" -- bash -c "PGPASSWORD=$postgres_password psql -U $postgres_superuser -c \"SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db_name' AND pid <> pg_backend_pid();\"" &>/dev/null || true
    
    # Drop the database
    log "INFO" "Dropping database '$db_name'"
    if ! kubectl_cmd exec -n "$postgres_namespace" "$postgres_pod" -- bash -c "PGPASSWORD=$postgres_password psql -U $postgres_superuser -c \"DROP DATABASE IF EXISTS $db_name;\"" &>/dev/null; then
        log "ERROR" "Failed to drop database '$db_name'"
        log "INFO" "Check postgres superuser credentials (POSTGRES_USER: $postgres_superuser, POSTGRES_PASSWORD: $postgres_password)"
        exit 1
    fi
    
    # Recreate the database
    log "INFO" "Recreating database '$db_name' with owner '$db_user'"
    if ! kubectl_cmd exec -n "$postgres_namespace" "$postgres_pod" -- bash -c "PGPASSWORD=$postgres_password psql -U $postgres_superuser -c \"CREATE DATABASE $db_name OWNER $db_user;\"" &>/dev/null; then
        log "ERROR" "Failed to recreate database '$db_name'"
        log "INFO" "Check postgres superuser credentials (POSTGRES_USER: $postgres_superuser, POSTGRES_PASSWORD: $postgres_password)"
        exit 1
    fi
    
    log "SUCCESS" "Database dropped and recreated successfully"
    log "INFO" "All tables removed"
    
    # Verify schema is empty
    log "STEP" "Verifying schema deletion"
    local remaining_tables=$(kubectl_cmd exec -n "$postgres_namespace" "$postgres_pod" -- bash -c "PGPASSWORD=$db_password psql -U $db_user -d $db_name -t -c \"SELECT COUNT(*) FROM pg_tables WHERE schemaname='public';\"")
    
    if [[ "$remaining_tables" -eq 0 ]]; then
        log "SUCCESS" "All tables deleted successfully"
        log "INFO" "Schema is now empty"
    else
        log "WARN" "Some tables may still exist: $remaining_tables remaining"
        # List remaining tables for debugging
        local remaining_list=$(kubectl_cmd exec -n "$postgres_namespace" "$postgres_pod" -- bash -c "PGPASSWORD=$db_password psql -U $db_user -d $db_name -t -c \"SELECT tablename FROM pg_tables WHERE schemaname='public' ORDER BY tablename;\"")
        if [[ -n "$remaining_list" ]]; then
            log "INFO" "Remaining tables:"
            echo "$remaining_list" | while read -r table; do
                echo "  - $table"
            done
        fi
    fi
    
    echo ""
    log "SUCCESS" "Grafana schema deletion completed"
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================

# Function to display usage information
usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Delete all Grafana tables from the PostgreSQL database.

WARNING: This will permanently delete ALL Grafana data!

OPTIONS:
    -h, --help                Show this help message
    -n, --namespace NAME      PostgreSQL namespace [default: postgres]
    -p, --pod NAME           PostgreSQL pod name [default: postgres-postgresql-0]
    -d, --database NAME       Database name [default: grafana]
    -u, --user NAME           Database user [default: grafana]
    --password PASSWORD       Database password [default: from .env]
    --postgres-user NAME      PostgreSQL superuser [default: postgres]
    --postgres-password PASSWORD PostgreSQL superuser password [default: from .env]
    --no-confirm              Skip confirmation prompt (DANGEROUS!)

EXAMPLES:
    $0                         # Delete Grafana schema with default settings
    $0 --no-confirm            # Delete without confirmation (use with caution!)
    $0 -d mydb -u myuser      # Delete from custom database/user

ENVIRONMENT VARIABLES:
    DB_NAME                   Database name (default: grafana)
    DB_USER                   Database user (default: grafana)
    DB_PASSWORD               Database password (default: grafana_password123)
    POSTGRES_USER             PostgreSQL superuser (default: postgres)
    POSTGRES_PASSWORD         PostgreSQL superuser password (default: changeme123)

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
            -n|--namespace)
                export POSTGRES_NAMESPACE="$2"
                shift 2
                ;;
            -p|--pod)
                export POSTGRES_POD="$2"
                shift 2
                ;;
            -d|--database)
                export DB_NAME="$2"
                shift 2
                ;;
            -u|--user)
                export DB_USER="$2"
                shift 2
                ;;
            --password)
                export DB_PASSWORD="$2"
                shift 2
                ;;
            --postgres-user)
                export POSTGRES_USER="$2"
                shift 2
                ;;
            --postgres-password)
                export POSTGRES_PASSWORD="$2"
                shift 2
                ;;
            --no-confirm)
                export SKIP_CONFIRM="true"
                shift
                ;;
            *)
                log_and_exit "ERROR" "Unknown option: $1"
                ;;
        esac
    done
}

# Main function
main() {
    # Parse command line arguments
    parse_arguments "$@"
    
    # Set defaults
    local postgres_namespace="${POSTGRES_NAMESPACE:-postgres}"
    local postgres_pod="${POSTGRES_POD:-postgres-postgresql-0}"
    local db_name="${DB_NAME:-grafana}"
    local db_user="${DB_USER:-grafana}"
    local db_password="${DB_PASSWORD:-grafana_password123}"
    local postgres_superuser="${POSTGRES_USER:-postgres}"
    local postgres_password="${POSTGRES_PASSWORD:-changeme123}"
    
    # Load environment variables if .env exists
    if [[ -f "$PROJECT_ROOT/.env" ]]; then
        log "INFO" "Loading environment variables from .env"
        set -a
        source "$PROJECT_ROOT/.env"
        set +a
        
        # Override with command line values if set
        db_name="${DB_NAME:-$db_name}"
        db_user="${DB_USER:-$db_user}"
        db_password="${DB_PASSWORD:-$db_password}"
        postgres_superuser="${POSTGRES_USER:-$postgres_superuser}"
        postgres_password="${POSTGRES_PASSWORD:-$postgres_password}"
    fi
    
    # Confirm deletion unless --no-confirm flag is set
    if [[ "${SKIP_CONFIRM:-false}" != "true" ]]; then
        confirm_deletion "$db_name"
    fi
    
    # Delete Grafana schema
    delete_grafana_schema "$db_name" "$db_user" "$db_password" "$postgres_namespace" "$postgres_pod" "$postgres_superuser" "$postgres_password"
}

# =============================================================================
# SCRIPT EXECUTION
# =============================================================================

# Run main function with all arguments
main "$@"
