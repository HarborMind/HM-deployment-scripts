#!/bin/bash
# =============================================================================
# HarborMind Azure AD App Registration - Microsoft Graph API Permissions Setup
# =============================================================================
#
# This script configures the required Microsoft Graph API permissions for the
# HarborMind M365 integration Azure AD app registration.
#
# Prerequisites:
#   - Azure CLI installed and authenticated (az login)
#   - Admin consent capability in the target tenant
#   - App registration already exists
#
# Usage:
#   ./setup-azure-ad-permissions.sh [--app-id <app-id>] [--dry-run] [--grant-consent]
#
# Examples:
#   ./setup-azure-ad-permissions.sh --dry-run                    # Show what would be added
#   ./setup-azure-ad-permissions.sh                              # Add permissions (no consent)
#   ./setup-azure-ad-permissions.sh --grant-consent              # Add permissions and grant admin consent
#   ./setup-azure-ad-permissions.sh --app-id abc-123 --grant-consent
#
# =============================================================================

set -euo pipefail

# Default HarborMind M365 App Client ID
DEFAULT_APP_ID="8ff56f95-acf7-42fc-8291-fab9bea47821"

# Microsoft Graph API App ID (constant)
MS_GRAPH_APP_ID="00000003-0000-0000-c000-000000000000"

# =============================================================================
# Required Microsoft Graph API Permissions (Application type - app-only)
# =============================================================================
# These are the permission IDs from Microsoft Graph API manifest
# Reference: https://learn.microsoft.com/en-us/graph/permissions-reference

declare -A REQUIRED_PERMISSIONS=(
    # Core M365 Integration
    ["Organization.Read.All"]="498476ce-e0fe-48b0-b801-37ba7e2685c6"          # Read organization info
    ["User.Read.All"]="df021288-bdef-4463-88db-98f22de89214"                  # Read all users (Entra ID)
    ["Group.Read.All"]="5b567255-7703-4780-807c-7be8301ae99b"                 # Read all groups (Entra ID)
    ["Directory.Read.All"]="7ab1d382-f21e-4acd-a863-ba3e13f7da61"             # Read directory data

    # SharePoint / OneDrive
    ["Sites.Read.All"]="332a536c-c7ef-4017-ab91-336970924f0d"                 # Read SharePoint sites
    ["Sites.ReadWrite.All"]="9492366f-7969-46a4-8d15-ed1a20078fff"            # Read/write SharePoint sites
    ["Files.Read.All"]="01d4889c-1287-42c6-ac1f-5d1e02578ef6"                 # Read all files

    # Intune / Device Management
    ["DeviceManagementManagedDevices.Read.All"]="2f51be20-0bb4-4fed-bf7b-db946066c75e"  # Read Intune devices
    ["DeviceManagementConfiguration.Read.All"]="dc377aa6-52d8-4e23-b271-2a7ae04cedf3"  # Read device config

    # Purview Information Protection (Sensitivity Labels)
    ["InformationProtectionPolicy.Read.All"]="19da66cb-0f37-4de8-a82b-45aa6e95e2a5"    # Read sensitivity labels

    # Policies (Copilot guardrails, data access policies)
    ["Policy.Read.All"]="246dd0d5-5bd0-4def-940b-0421030a5b68"                # Read all policies

    # Application Registration (Copilot agents)
    ["Application.Read.All"]="9a5d68dd-52b0-4cc2-bd40-abcf44ac3a30"           # Read all app registrations
    ["ServicePrincipalEndpoint.Read.All"]="5256681e-b7f6-40c0-8447-2d9db68797a0"  # Read service principal endpoints

    # Microsoft 365 Copilot (AI/LLM auditing and monitoring)
    ["AIEvent.Read.All"]="636e1b0e-daa5-4a91-97f9-7c4a8e5b5e5a"               # Read AI/Copilot events (preview)

    # Audit Logs (for compliance and monitoring)
    ["AuditLog.Read.All"]="b0afded3-3588-46d8-8b3d-9842eff778da"              # Read audit logs

    # Reports (for usage analytics)
    ["Reports.Read.All"]="230c1aed-a721-4c5d-9cb4-a90514e508ef"               # Read usage reports

    # Security (for threat detection)
    ["SecurityEvents.Read.All"]="bf394140-e372-4bf9-a898-299cfc7564e5"        # Read security events
    ["SecurityAlert.Read.All"]="472e4a4d-bb4a-4026-98d1-0b0d74cb7d56"         # Read security alerts

    # Mail (for sensitivity scanning - optional)
    ["Mail.Read"]="810c84a8-4a9e-49e6-bf7d-12d183f40d01"                      # Read all mail (app-level)

    # Teams (for collaboration security)
    ["ChannelMessage.Read.All"]="7b2449af-6ccd-4f4d-9f78-e550c193f0d2"        # Read Teams messages
    ["Chat.Read.All"]="6b7d71aa-70aa-4810-a8d9-5d9fb2830017"                  # Read all chats
)

# =============================================================================
# Parse Arguments
# =============================================================================

APP_ID="$DEFAULT_APP_ID"
DRY_RUN=false
GRANT_CONSENT=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --app-id)
            APP_ID="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --grant-consent)
            GRANT_CONSENT=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--app-id <app-id>] [--dry-run] [--grant-consent]"
            echo ""
            echo "Options:"
            echo "  --app-id <id>     Azure AD App Client ID (default: $DEFAULT_APP_ID)"
            echo "  --dry-run         Show what would be added without making changes"
            echo "  --grant-consent   Grant admin consent after adding permissions"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# =============================================================================
# Functions
# =============================================================================

log_info() {
    echo "[INFO] $1"
}

log_success() {
    echo "[SUCCESS] $1"
}

log_warning() {
    echo "[WARNING] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

check_azure_cli() {
    if ! command -v az &> /dev/null; then
        log_error "Azure CLI is not installed. Please install it first:"
        log_error "  https://docs.microsoft.com/en-us/cli/azure/install-azure-cli"
        exit 1
    fi

    # Check if logged in
    if ! az account show &> /dev/null; then
        log_error "Not logged into Azure CLI. Please run: az login"
        exit 1
    fi

    log_info "Azure CLI authenticated as: $(az account show --query user.name -o tsv)"
}

get_current_permissions() {
    log_info "Fetching current permissions for app: $APP_ID"

    # Get the app's required resource access
    az ad app show --id "$APP_ID" --query "requiredResourceAccess[?resourceAppId=='$MS_GRAPH_APP_ID'].resourceAccess[].id" -o tsv 2>/dev/null || echo ""
}

add_permissions() {
    local current_permissions
    current_permissions=$(get_current_permissions)

    log_info "Building permission manifest..."

    # Build the resource access JSON
    local resource_access="["
    local first=true
    local added_count=0
    local skipped_count=0

    for permission_name in "${!REQUIRED_PERMISSIONS[@]}"; do
        local permission_id="${REQUIRED_PERMISSIONS[$permission_name]}"

        if echo "$current_permissions" | grep -q "$permission_id"; then
            log_info "  [SKIP] $permission_name - already granted"
            ((skipped_count++))
        else
            if [ "$first" = true ]; then
                first=false
            else
                resource_access+=","
            fi
            resource_access+="{\"id\":\"$permission_id\",\"type\":\"Role\"}"
            log_info "  [ADD]  $permission_name"
            ((added_count++))
        fi
    done

    resource_access+="]"

    echo ""
    log_info "Summary: $added_count to add, $skipped_count already present"
    echo ""

    if [ "$added_count" -eq 0 ]; then
        log_success "All required permissions are already configured!"
        return 0
    fi

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would add $added_count permissions"
        log_info "[DRY RUN] Resource access JSON:"
        echo "$resource_access" | jq '.'
        return 0
    fi

    # Create the full required resource access structure
    local full_manifest="[{\"resourceAppId\":\"$MS_GRAPH_APP_ID\",\"resourceAccess\":$resource_access}]"

    log_info "Updating app registration..."

    # Update the app registration
    if az ad app update --id "$APP_ID" --required-resource-accesses "$full_manifest"; then
        log_success "Permissions added successfully!"
    else
        log_error "Failed to update app registration"
        return 1
    fi
}

grant_admin_consent() {
    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] Would grant admin consent for Microsoft Graph permissions"
        return 0
    fi

    log_info "Granting admin consent for Microsoft Graph permissions..."

    # Get the service principal object ID
    local sp_id
    sp_id=$(az ad sp show --id "$APP_ID" --query id -o tsv 2>/dev/null)

    if [ -z "$sp_id" ]; then
        log_warning "Service principal not found. Creating one..."
        sp_id=$(az ad sp create --id "$APP_ID" --query id -o tsv)
    fi

    # Grant consent via the Graph API
    # Note: This requires Directory.ReadWrite.All or similar admin permission
    if az ad app permission admin-consent --id "$APP_ID" 2>/dev/null; then
        log_success "Admin consent granted successfully!"
    else
        log_warning "Could not auto-grant admin consent."
        log_warning "Please grant consent manually in Azure Portal:"
        log_warning "  https://portal.azure.com/#view/Microsoft_AAD_RegisteredApps/ApplicationMenuBlade/~/CallAnAPI/appId/$APP_ID"
        log_warning ""
        log_warning "Or use this URL pattern for tenant-specific consent:"
        log_warning "  https://login.microsoftonline.com/{tenant-id}/adminconsent?client_id=$APP_ID"
    fi
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo "=============================================="
    echo "HarborMind Azure AD Permissions Setup"
    echo "=============================================="
    echo ""

    log_info "App ID: $APP_ID"
    log_info "Dry Run: $DRY_RUN"
    log_info "Grant Consent: $GRANT_CONSENT"
    echo ""

    check_azure_cli

    echo ""
    log_info "Required Microsoft Graph API Permissions:"
    echo "----------------------------------------------"
    for permission_name in "${!REQUIRED_PERMISSIONS[@]}"; do
        echo "  - $permission_name"
    done
    echo ""

    add_permissions

    if [ "$GRANT_CONSENT" = true ]; then
        echo ""
        grant_admin_consent
    fi

    echo ""
    echo "=============================================="
    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run complete. No changes were made."
    else
        log_success "Setup complete!"
        if [ "$GRANT_CONSENT" = false ]; then
            log_warning "Remember to grant admin consent in Azure Portal!"
        fi
    fi
    echo "=============================================="
}

main
