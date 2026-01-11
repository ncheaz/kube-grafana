#!/bin/bash

# =============================================================================
# GRAFANA DATABASE PASSWORD FIX SCRIPT
# =============================================================================
# This script updates the admin password in the Grafana PostgreSQL database
# by generating the proper pbkdf2 hash format that Grafana expects.

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

kubectl_cmd() {
    if [[ "$USE_MICROK8S" == "true" ]]; then
        multipass exec "$MICROK8S_VM" -- microk8s kubectl "$@"
    else
        kubectl "$@"
    fi
}

# =============================================================================
# DATABASE PASSWORD FIX
# =============================================================================

fix_database_password() {
    log "HEADER" "Fixing Grafana Database Password"
    
    # Load environment variables
    load_env
    
    # Get the password from .env
    local password="$GRAFANA_ADMIN_PASSWORD"
    local db_password="$DB_PASSWORD"
    local db_user="$DB_USER"
    local db_name="$DB_NAME"
    local db_host="$DB_HOST"
    
    log "INFO" "Admin password from .env: $password"
    log "INFO" "Database: $db_user@$db_host/$db_name"
    
    # Get the current salt from the database
    log "STEP" "Retrieving current salt from database"
    local salt=$(kubectl_cmd exec -n postgres postgres-postgresql-0 -- bash -c "PGPASSWORD=$db_password psql -U $db_user -d $db_name -t -c \"SELECT salt FROM \\\"user\\\" WHERE login = 'admin';\"" | xargs)
    
    if [[ -z "$salt" ]]; then
        log_and_exit "ERROR" "Could not retrieve salt from database"
    fi
    
    log "INFO" "Current salt: $salt"
    
    # Generate pbkdf2 hash
    # Grafana uses pbkdf2_sha256 with 10000 iterations
    log "STEP" "Generating pbkdf2 hash"
    
    # Use Python to generate the hash since it has built-in pbkdf2 support
    local hash=$(python3 -c "
import hashlib
import base64
import binascii

password = '$password'
salt = '$salt'
iterations = 10000

# Generate the hash
dk = hashlib.pbkdf2_hmac('sha256', password.encode('utf-8'), salt.encode('utf-8'), iterations)
hash_b64 = base64.b64encode(dk).decode('utf-8')

# Format: pbkdf2_sha256\$iterations\$salt\$hash
print(f'pbkdf2_sha256\${iterations}\${salt}\${hash_b64}')
")
    
    if [[ -z "$hash" ]]; then
        log_and_exit "ERROR" "Failed to generate pbkdf2 hash"
    fi
    
    log "INFO" "Generated hash: $hash"
    
    # For MicroK8s, create the SQL file directly in the VM using a heredoc
    if [[ "$USE_MICROK8S" == "true" ]]; then
        log "STEP" "Updating password in database"
        multipass exec "$MICROK8S_VM" -- bash -c "cat > /tmp/update-password.sql << 'SQLEOF'
UPDATE \"user\" SET password = '$hash' WHERE login = 'admin';
SQLEOF"
        
        # Copy the SQL file from VM to pod
        multipass exec "$MICROK8S_VM" -- microk8s kubectl cp /tmp/update-password.sql postgres/postgres-postgresql-0:/tmp/update-password.sql -n postgres
        
        # Execute the SQL from within the VM
        multipass exec "$MICROK8S_VM" -- bash -c "PGPASSWORD=$db_password microk8s kubectl exec -n postgres postgres-postgresql-0 -- bash -c \"PGPASSWORD=$db_password psql -U $db_user -d $db_name -f /tmp/update-password.sql\""
        
        # Clean up
        multipass exec "$MICROK8S_VM" -- microk8s kubectl exec -n postgres postgres-postgresql-0 -- rm -f /tmp/update-password.sql
        multipass exec "$MICROK8S_VM" -- rm -f /tmp/update-password.sql
    else
        # Write SQL to a temporary file
        local temp_sql_file="/tmp/update-password-$$.sql"
        echo "UPDATE \"user\" SET password = '$hash' WHERE login = 'admin';" > "$temp_sql_file"
        
        # Copy the SQL file to the pod
        kubectl_cmd cp "$temp_sql_file" postgres/postgres-postgresql-0:/tmp/update-password.sql
        
        # Execute the SQL
        log "STEP" "Updating password in database"
        kubectl_cmd exec -n postgres postgres-postgresql-0 -- bash -c "PGPASSWORD=$db_password psql -U $db_user -d $db_name -f /tmp/update-password.sql"
        
        # Clean up
        rm -f "$temp_sql_file"
        kubectl_cmd exec -n postgres postgres-postgresql-0 -- rm -f /tmp/update-password.sql
    fi
    
    if [[ $? -eq 0 ]]; then
        log "SUCCESS" "Database password updated successfully"
    else
        log_and_exit "ERROR" "Failed to update database password"
    fi
    
    # Verify the update
    log "STEP" "Verifying password update"
    local updated_hash=$(kubectl_cmd exec -n postgres postgres-postgresql-0 -- bash -c "PGPASSWORD=$db_password psql -U $db_user -d $db_name -t -A -c \"SELECT password FROM \\\"user\\\" WHERE login = 'admin';\"")
    
    if [[ "$updated_hash" == "$hash" ]]; then
        log "SUCCESS" "Password verification successful"
    else
        log "WARN" "Password verification failed, but update may have succeeded"
        log "INFO" "Expected: $hash"
        log "INFO" "Got: $updated_hash"
    fi
    
    log "HEADER" "Database Password Fix Complete"
    log "INFO" "You can now login with:"
    log "INFO" "Username: admin"
    log "INFO" "Password: $password"
}

# =============================================================================
# MAIN FUNCTION
# =============================================================================

main() {
    # Initialize script
    log "HEADER" "Starting fix-db-password.sh"
    load_env
    
    # Fix the database password
    fix_database_password
}

# Run main function
main "$@"
