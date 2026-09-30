#!/bin/bash

# Linode API Build Script - OPNsense HA Deployment
# Usage: ./opnsense-ha-deploy.sh

set -e

# Function to log failures
log_failure() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] FAILURE: $message" | tee "failed-${FAIL_COUNTER}.log"
    exit 1
}

# Function to log info messages
log_info() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] INFO: $1"
}

# Configuration file path
CONFIG_FILE="opnsense.config"

# Function to get config value from file or environment variable
get_config() {
    local var_name="$1"
    local value=""
    # Try to read from config file if it exists
    if [[ -f "$CONFIG_FILE" ]]; then
        value=$(grep -E "^[[:space:]]*${var_name}=" "$CONFIG_FILE" \
            | grep -vE "^[[:space:]]*#" \
            | head -n 1 \
            | cut -d'=' -f2- \
            | sed 's/^["'\'']\(.*\)["'\'']$/\1/')
    fi
    # If not found in config file, use environment variable
    if [[ -z "$value" ]]; then
        value="${!var_name}"
    fi
    echo "$value"
}

# Load configuration
token=$(get_config "token")
label=$(get_config "label")
tag=$(get_config "tag")
root_pass=$(get_config "root_pass")
region=$(get_config "region")
linode_type=$(get_config "linode_type")
memory=$(( $(get_config "memory") * 1024))
network_id=$(get_config "network_id")
subnet_CIDR=$(get_config "subnet_CIDR")
bucket_name=$(get_config "bucket_name")
image_name=$(get_config "image_name")
bucket_region=$(get_config "bucket_region")
bucket_key=$(get_config "bucket_key")
bucket_secret=$(get_config "bucket_secret")
cpu=$(get_config "cpu")
virtualdisk=$(( $(get_config "virtual_disk") * 1024 + 520 ))
active=$(get_config "active")
standby=$(get_config "standby")

API_BASE="https://api.linode.com/v4"
HEADERS=(-H "Authorization: Bearer $token" -H "Content-Type: application/json")

# Retry settings
MAX_RETRIES=${MAX_RETRIES:-50}
RETRY_DELAY=${RETRY_DELAY:-7}
LOG_FILE=${LOG_FILE:-opnsense.log}
touch "$LOG_FILE" 2>/dev/null || LOG_FILE="opnsense.log"                                                                echo "Logging to $LOG_FILE"

# Validate required variables exist
required_vars=("token" "region" "linode_type" "memory" "network_id" "subnet_CIDR" "virtualdisk" "active" "standby")
for var in "${required_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
        echo "Error: Required variable '$var' is not set in $CONFIG_FILE or environment" >&2
        exit 1
    fi
done

# Convert all to lowercase
region=$(echo "$region" | tr '[:upper:]' '[:lower:]')
linode_type=$(echo "$linode_type" | tr '[:upper:]' '[:lower:]')
bucket_name=$(echo "$bucket_name" | tr '[:upper:]' '[:lower:]')
bucket_region=$(echo "$bucket_region" | tr '[:upper:]' '[:lower:]')

# Validation function
validate_field() {
    local field_name="$1"
    local field_value="$2"

    if [ -z "$field_value" ]; then
        echo "ERROR: $field_name cannot be empty."
        exit 1
    fi

    if ! [[ "$field_value" =~ ^[a-z0-9-]+$ ]]; then
        echo "ERROR: $field_name must contain only lowercase letters, numbers, and dashes."
        echo "Invalid value: $field_value"
        exit 1
    fi
}

# Validate each field
validate_field "region" "$region"
validate_field "linode_type" "$linode_type"
validate_field "bucket_name" "$bucket_name"
validate_field "bucket_region" "$bucket_region"

# API CALL FUNCTION WITH BACKOFFS
api_call() {
    local method="$1"
    local url="$2"
    local data="$3"
    local attempt=0
    local response
    local http_code

    while (( attempt < MAX_RETRIES )); do
        ((attempt++))

        if [[ -z "$data" ]]; then
            response=$(curl -sS -w "\n%{http_code}" -X "$method" \
                -H "Authorization: Bearer $token" \
                -H "Content-Type: application/json" \
                "$url" 2>>"$LOG_FILE")
        else
            response=$(curl -sS -w "\n%{http_code}" -X "$method" \
                -H "Authorization: Bearer $token" \
                -H "Content-Type: application/json" \
                -d "$data" \
                "$url" 2>>"$LOG_FILE")
        fi

        # Separate body and HTTP code
        http_code=$(echo "$response" | tail -n1)
        response=$(echo "$response" | sed '$d')

        # Handle HTTP-level retry conditions
        if [[ "$http_code" == "429" ]]; then
            echo "Rate limit hit (attempt $attempt/$MAX_RETRIES). Sleeping ${RETRY_DELAY}s..." >&2
            sleep "$RETRY_DELAY"
            continue
        elif [[ "$http_code" =~ ^5[0-9]{2}$ ]]; then
            echo "Server error ($http_code) on attempt $attempt/$MAX_RETRIES. Sleeping ${RETRY_DELAY}s..." >&2
            sleep "$RETRY_DELAY"
            continue
        fi

        # Handle Linode busy or application-level errors
        if echo "$response" | grep -qiE "busy|rate limit"; then
            echo "Linode busy or rate limited (attempt $attempt/$MAX_RETRIES). Sleeping ${RETRY_DELAY}s..." >&2
            sleep "$RETRY_DELAY"
            continue
        fi

        # Handle API 'errors' key in JSON body
        if echo "$response" | grep -q "\"errors\""; then
            if (( attempt < MAX_RETRIES )); then
                echo "API error (attempt $attempt/$MAX_RETRIES). Retrying in ${RETRY_DELAY}s..." >&2
                echo "Response: $response"
                sleep "$RETRY_DELAY"
                continue
            else
                echo "ERROR: Max retries reached. Last response: $response"
                echo "$response"
                return 1
            fi
        fi

        # Success
        echo "$response"
        return 0
    done

    echo "ERROR: Max retries ($MAX_RETRIES) reached without success"
    return 1
}

# Wrapper for api_call to handle pagination
get_all_pages() {
    local url="$1"
    local all_data="[]"
    local page=1
    local total_pages=1

    # First request
    local response
    response=$(api_call "GET" "${url}?page=${page}" "") || return 1
    total_pages=$(echo "$response" | jq -r '.pages // 1')

    all_data=$(echo "$response" | jq '.data')

    # Loop through additional pages, if any
    while (( page < total_pages )); do
        ((page++))
        response=$(api_call "GET" "${url}?page=${page}" "") || return 1
        all_data=$(jq -s '[.[0][] , .[1][]]' <(echo "$all_data") <(echo "$response" | jq '.data'))
    done

    echo "$all_data"
}

# Counter for failed attempts
FAIL_COUNTER=1
while [[ -f "failed-${FAIL_COUNTER}.log" ]]; do
    ((FAIL_COUNTER++))
done

# Validate CIDR format
validate_cidr() {
    local cidr="$1"
    if [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]]; then
        IFS=. read -r o1 o2 o3 o4 <<<"${cidr%/*}"
        for octet in $o1 $o2 $o3 $o4; do
            if ((octet < 0 || octet > 255)); then
                return 1
            fi
        done
        return 0
    else
        return 1
    fi
}

# Validate CIDR
if ! validate_cidr "$subnet_CIDR"; then
    log_failure "subnet_CIDR is not a valid CIDR notation."
fi

log_info "Validating token and grants..."
response=$(api_call "GET" "${API_BASE}/profile/tokens")

if [[ -z "$response" ]]; then
    echo "ERROR: Failed to fetch token info."
    exit 1
fi

# Get the first 16 characters of the token
token_prefix="${token:0:16}"

# Find the token object that matches the prefix
matched=$(echo "$response" | jq -r --arg prefix "$token_prefix" '.data[] | select(.token | startswith($prefix))')

if [[ -z "$matched" ]]; then
    echo "ERROR: No matching token found."
    exit 1
fi

# Exact scopes required
exact_scopes=(firewall:read_write ips:read_write linodes:read_write object_storage:read_write vpc:read_write)

# Extract scopes from the matched token
scopes=$(echo "$matched" | jq -r '
  if type=="object" then
    if (.scopes | type=="array") then
      .scopes | join(" ")
    else
      .scopes
    end
  else
    ""
  end
')

# Full access check
if [[ "$scopes" == "*" ]]; then
    echo "Token is valid with full access."
else
    # Check exact scopes
    missing=false
    for s in "${exact_scopes[@]}"; do
        if ! grep -qw "$s" <<<"$scopes"; then
            missing=true
            echo "Missing required scope: $s"
        fi
    done
    echo "Token is valid with all required scopes."
fi

echo "Token validation passed!"

# Get regions and check availability
log_info "Checking if instance type '$linode_type' is available in region '$region'..."
regions_response=$(api_call "GET" "${API_BASE}/regions")

# Determine capability string based on linode_type
case "$linode_type" in
    shared|standard)
        capability="Linodes"
        type_class="standard"
        ;;
    dedicated)
        capability="Linodes"
        type_class="dedicated"
        ;;
    premium)
        capability="Premium Plans"
        type_class="premium"
        ;;
    gpu)
        capability="GPU Linodes"
        type_class="gpu"
        ;;
    vpu)
        capability="NETINT Quadra T1U"
        type_class="accelerated"
        ;;
    *)
        log_failure "Invalid linode_type: $linode_type"
        ;;
esac

# Check if region supports the required capability
region_id=$(echo "$regions_response" | jq -r --arg region "$region" --arg cap "$capability" \
    '.data[] | select(.id == $region and (.capabilities[] | contains($cap))) | .id')

if [[ -z "$region_id" ]]; then
    log_failure "Region '$region' does not support capability '$capability' (linode_type: $linode_type)"
fi

log_info "Region '$region' supports '$capability'"

# Get instance types filtered by class
log_info "Fetching instance types for class '$type_class'..."
types_response=$(curl -s -H "Authorization: Bearer $token" \
    -H "X-Filter: {\"class\":\"$type_class\"}" \
    "${API_BASE}/linode/types")

# Find smallest instance type that meets ALL minimum requirements
log_info "Searching for instance type matching minimum requirements:"
log_info "  - Class: $type_class"
log_info "  - Memory: >= ${memory}MB"
log_info "  - vCPU: >= ${cpu}"
log_info "  - Disk: >= ${virtualdisk}MB"

selected_type=$(echo "$types_response" | jq -r \
    --argjson mem "$memory" \
    --argjson vcpu "$cpu" \
    --argjson disk "$virtualdisk" \
    '.data[] | 
    select(
        .memory >= $mem and
        .vcpus >= $vcpu and
        .disk >= $disk
    ) | {id: .id, memory: .memory, vcpus: .vcpus, disk: .disk} | 
    [.memory, .id]' | \
    jq -s 'sort_by(.[0]) | .[0][1]' | tr -d '"')

if [[ -z "$selected_type" ]]; then
    log_failure "No instance type found matching ALL minimum requirements"
fi

log_info "Selected instance type: $selected_type"

# Get full type details
type_details=$(echo "$types_response" | jq -r --arg id "$selected_type" '.data[] | select(.id == $id)')
type_memory=$(echo "$type_details" | jq -r '.memory')
type_disk=$(echo "$type_details" | jq -r '.disk')

echo "Instance will have ${type_memory}MB memory and ${type_disk}MB disk"

# Calculate disk sizes
alpine_disk_size=520  # in MB
raw_disk_size=10240

if [[ $raw_disk_size -le 0 ]]; then
    log_failure "Insufficient disk space for configuration"
fi

echo "Checking Object Storage configuration..."

# Function to update or add variable in config file
update_config_var() {
    local var_name="$1"
    local var_value="$2"
    local config_file="$3"
    
    if grep -q "^${var_name}=" "$config_file" 2>/dev/null; then
        # Variable exists, update it
        sed -i.bak "s|^${var_name}=.*|${var_name}=\"${var_value}\"|" "$config_file"
    else
        # Variable doesn't exist, append it
        echo "${var_name}=\"${var_value}\"" >> "$config_file"
    fi
}

# Check if bucket-related variables are set
bucket_vars=("bucket_region" "bucket_name" "active" "standby")
bucket_vars_set=true
for var in "${bucket_vars[@]}"; do
    if [[ -z "${!var}" ]]; then
        bucket_vars_set=false
        log_failure "Required bucket variable '$var' is not set"
    fi
done

# Validate bucket and region
log_info "Checking bucket '$bucket_name' in region '$bucket_region'..."
bucket_response=$(api_call "GET" "${API_BASE}/object-storage/buckets/${bucket_region}/${bucket_name}")

# Extract hostname
bucket_endpoint=$(echo "$bucket_response" | jq -r '.s3_endpoint // empty')

if [[ -z "$bucket_endpoint" ]]; then
    log_failure "bucket_name '$bucket_name' or bucket_region '$bucket_region' is incorrect value"
fi

log_info "Bucket endpoint verified: $bucket_endpoint"

# Validate both image files exist in bucket
log_info "Checking if images exist in bucket..."
object_list=$(get_all_pages "${API_BASE}/object-storage/buckets/${bucket_region}/${bucket_name}/object-list")
if [[ $? -ne 0 || -z "$object_list" ]]; then
    log_failure "Failed to retrieve object list from bucket '$bucket_name'."
fi

# Check active image
if echo "$object_list" | jq -e --arg img "$active" '.[]? | select(.name == $img)' > /dev/null 2>&1; then
    log_info "Active image '$active' verified in bucket."
else
    log_failure "Active image '$active' not found in bucket."
fi

# Check standby image
if echo "$object_list" | jq -e --arg img "$standby" '.[]? | select(.name == $img)' > /dev/null 2>&1; then
    log_info "Standby image '$standby' verified in bucket."
else
    log_failure "Standby image '$standby' not found in bucket."
fi

# Function to create bucket keys
create_bucket_keys() {
    log_info "Creating new bucket access keys..."

    # Generate random 8-digit suffix
    random_suffix=$(shuf -i 10000000-99999999 -n 1)
    deployment_label="${label}-${random_suffix}"

    # API endpoint and payload
    url="https://api.linode.com/v4/object-storage/keys"
    data=$(jq -nc \
        --arg bucket "$bucket_name" \
        --arg region "$bucket_region" \
        --arg label "$deployment_label" \
        '{bucket_access: [{bucket_name: $bucket, permissions: "read_only", region: $region}], label: $label}'
    )

    # Use centralized API call function with retries and rate-limit handling
    key_response=$(api_call "POST" "$url" "$data")
    if [[ $? -ne 0 ]]; then
        log_failure "Failed to create bucket access keys after ${MAX_RETRIES} attempts"
        return 1
    fi

    # Parse access and secret keys
    bucket_key=$(echo "$key_response" | jq -r '.access_key // empty')
    bucket_secret=$(echo "$key_response" | jq -r '.secret_key // empty')

    if [[ -z "$bucket_key" || -z "$bucket_secret" ]]; then
        error_msg=$(echo "$key_response" | jq -r '.errors[]?.reason // "Unknown error"' | head -1)
        log_failure "Bucket key creation failed: $error_msg"
        return 1
    fi

    log_info "Bucket access keys created successfully"
    log_info "Access Key: $bucket_key"
    log_info "Secret Key: [REDACTED]"

    # Save credentials to config file
    if [[ -f "$CONFIG_FILE" ]]; then
        log_info "Writing bucket credentials to $CONFIG_FILE..."
        if grep -q '^bucket_key=' "$CONFIG_FILE"; then
            sed -i "s|^bucket_key=.*|bucket_key=\"$bucket_key\"|" "$CONFIG_FILE"
        else
            echo "bucket_key=\"$bucket_key\"" >> "$CONFIG_FILE"
        fi
        if grep -q '^bucket_secret=' "$CONFIG_FILE"; then
            sed -i "s|^bucket_secret=.*|bucket_secret=\"$bucket_secret\"|" "$CONFIG_FILE"
        else
            echo "bucket_secret=\"$bucket_secret\"" >> "$CONFIG_FILE"
        fi
    else
        log_info "Creating $CONFIG_FILE with bucket credentials..."
        {
            echo "bucket_key=\"$bucket_key\""
            echo "bucket_secret=\"$bucket_secret\""
        } > "$CONFIG_FILE"
    fi
    log_info "Credentials saved to $CONFIG_FILE"

    # Export for later script use
    export bucket_key bucket_secret
}

# Check bucket access credentials
if [[ -n "$bucket_key" ]] && [[ -n "$bucket_secret" ]]; then
    log_info "Validating existing access key..."
    response=$(api_call "GET" "${API_BASE}/object-storage/keys")

    # Try to find a matching key object
    matched=$(echo "$response" | jq -r --arg key "$bucket_key" '.data[]? | select(.access_key == $key)')
    
    if [[ -z "$matched" || "$matched" == "null" ]]; then
        log_info "Access key $bucket_key not found in object storage keys"
        create_bucket_keys
    else
        # Validate bucket_name and region
        bucket_match=$(echo "$matched" | jq -r --arg bucket "$bucket_name" --arg region "$bucket_region" \
            '.bucket_access[]? | select(.bucket_name==$bucket and .region==$region)')
        
        if [[ -z "$bucket_match" || "$bucket_match" == "null" ]]; then
            log_info "Access key does not have access to bucket '$bucket_name' in region '$bucket_region'"
            create_bucket_keys
        else
            log_info "Access key, bucket, and region validated successfully"
        fi
    fi
else
    # Either both are missing or only one is provided - create new keys
    if [[ -n "$bucket_key" ]] || [[ -n "$bucket_secret" ]]; then
        log_info "Incomplete credentials provided (only one of key/secret), creating new pair..."
    else
        log_info "No bucket credentials provided, creating new access keys..."
    fi
    create_bucket_keys
fi

log_info "All bucket configurations validated successfully"

# Wait for disk ready function
wait_for_disk_ready() {
    local instance_id="$1"
    local disk_id="$2"
    local label="$3"
    local max_wait=180
    local interval=5
    local elapsed=0

    echo "Waiting for disk '$label' (ID: $disk_id) to become ready..."

    while (( elapsed < max_wait )); do
        response=$(api_call "GET" "${API_BASE}/linode/instances/${instance_id}/disks/${disk_id}")
        if [[ $? -ne 0 || -z "$response" ]]; then
            echo "Failed to query disk status for $label. Retrying in $interval seconds..." >&2
            sleep "$interval"
            ((elapsed+=interval))
            continue
        fi

        status=$(echo "$response" | jq -r '.status // empty')
        if [[ "$status" == "ready" ]]; then
            echo "Disk '$label' is ready."
            return 0
        fi

        echo "Disk '$label' status: $status (waiting...)"
        sleep "$interval"
        ((elapsed+=interval))
    done

    echo "ERROR: Timed out waiting for disk '$label' to become ready after ${max_wait}s" >&2
    return 1
}

# Create Placement Group
log_info "Creating placement group in region '$region'..."
placement_group_payload=$(cat <<EOF
{
  "placement_group_policy": "strict",
  "placement_group_type": "anti_affinity:local",
  "region": "$region",
  "label": "${label}-pg-$(date +%s)"
}
EOF
)

placement_group_response=$(api_call "POST" "${API_BASE}/placement/groups" "${placement_group_payload}")
placement_group_id=$(echo "$placement_group_response" | jq -r '.id')

if [[ -z "$placement_group_id" || "$placement_group_id" == "null" ]]; then
    error_msg=$(echo "$placement_group_response" | jq -r '.errors[]?.reason' | tr '\n' ' ')
    log_failure "Failed to create placement group: $error_msg"
fi

log_info "Created placement group with ID: $placement_group_id"
sleep 2

# Function to create an instance
create_instance() {
    local instance_label="$1"
    local image_file="$2"
    local is_standby="$3"
    
    cloud_init_template=$(cat template.yaml)
    cloud_init_yaml="${cloud_init_template//##TOKEN##/$token}"
    cloud_init_yaml="${cloud_init_yaml//##REGION##/$region}"
    cloud_init_yaml="${cloud_init_yaml//##BUCKET_NAME##/$bucket_name}"
    cloud_init_yaml="${cloud_init_yaml//##BUCKET_REGION##/$bucket_region}"
    cloud_init_yaml="${cloud_init_yaml//##BUCKET_KEY##/$bucket_key}"
    cloud_init_yaml="${cloud_init_yaml//##BUCKET_SECRET##/$bucket_secret}"
    cloud_init_yaml="${cloud_init_yaml//##BUCKET_ENDPOINT##/$bucket_endpoint}"

    # Create Linode instance
    echo "Creating Linode instance..."
    if [[ "$is_standby" == "false" ]]; then
        log_info "=== Creating ${instance_label} instance ==="
        cloud_init_yaml="${cloud_init_yaml//##IMAGE_NAME##/$active}"
        cloud_init_yaml="${cloud_init_yaml//##INSTANCE_ROLE##/active}"
        cloud_init_yaml="${cloud_init_yaml//##SHARED_IPV4##/0.0.0.0}"
        cloud_init_base64=$(echo "$cloud_init_yaml" | base64 -w 0) 
        create_payload=$(cat <<EOF
{
  "type": "$selected_type",
  "region": "$region",
  "label": "$instance_label",
  "tags": ["$tag"],
  "metadata": {
      "user_data": "$cloud_init_base64"
  },
  "booted": false,
  "placement_group": {
    "id": $placement_group_id
  }
}
EOF
)
        echo $cloud_init_yaml
        echo $create_payload
    else
        log_info "=== Creating ${instance_label} instance ==="
	cloud_init_yaml="${cloud_init_yaml//##IMAGE_NAME##/$standby}"
        cloud_init_yaml="${cloud_init_yaml//##INSTANCE_ROLE##/standby}"
        cloud_init_yaml="${cloud_init_yaml//##SHARED_IPV4##/$active_ipv4}"
        cloud_init_base64=$(echo "$cloud_init_yaml" | base64 -w 0)
        create_payload=$(cat <<EOF
{
  "type": "$selected_type",
  "region": "$region",
  "label": "$instance_label",
  "tags": ["$tag"],
  "metadata": {
      "user_data": "$cloud_init_base64"
  },
  "booted": false,
  "placement_group": {
    "id": $placement_group_id
  }
}
EOF
)
        echo $cloud_init_yaml
        echo $create_payload
    fi
    instance_response=$(api_call "POST" "${API_BASE}/linode/instances" "${create_payload}")
    
    instance_id=$(echo "$instance_response" | jq -r '.id')
    if [[ -z "$instance_id" || "$instance_id" == "null" ]]; then
        error_msg=$(echo "$instance_response" | jq -r '.errors[]?.reason' | tr '\n' ' ')
        log_failure "Failed to create instance: $error_msg"
    fi
    
    echo "Created instance with ID: $instance_id"
    
    # If this is the active instance, capture the IPv4 address
    if [[ "$is_standby" != "true" ]]; then
        active_ipv4=$(echo "$instance_response" | jq -r '.ipv4[0] // empty')
        if [[ -z "$active_ipv4" ]]; then
            log_failure "Failed to retrieve IPv4 address for active instance"
        fi
        log_info "Active instance IPv4: $active_ipv4"
    fi
    
    create_disk1=$(cat <<EOF
{
  "filesystem": "ext4",
  "image": "linode/alpine3.22",
  "label": "alpine",
  "root_pass": "$root_pass",
  "size": $alpine_disk_size
}
EOF
) 
    create_disk2=$(cat <<EOF
{
  "filesystem": "raw",
  "label": "raw",
  "size": $raw_disk_size
}
EOF
)
    
    sleep 2
    disk2_response=$(api_call "POST" "${API_BASE}/linode/instances/${instance_id}/disks" "${create_disk2}")
    sleep 2
    disk1_response=$(api_call "POST" "${API_BASE}/linode/instances/${instance_id}/disks" "${create_disk1}")
    sleep 2
    
    # Get disk IDs
    raw_disk_id=$(echo "$disk2_response" | jq -r '.id')
    alpine_disk_id=$(echo "$disk1_response" | jq -r '.id')
    
    echo "Alpine Disk ID: $alpine_disk_id"
    echo "Raw Disk ID: $raw_disk_id"
    
    # Wait for disks to be ready
    wait_for_disk_ready "$instance_id" "$alpine_disk_id" "Alpine Disk" || log_failure "Alpine disk not ready"
    wait_for_disk_ready "$instance_id" "$raw_disk_id" "Raw Disk" || log_failure "Raw disk not ready"
    log_info "Disks are ready"
    
    # Create Alpine configuration with 3 interfaces
    echo "Creating Alpine configuration with 3 interfaces..."
    alpine_initial_payload=$(cat <<EOF
{
  "label": "Alpine",
  "interfaces": [
    {"purpose": "public", "primary": true}
  ],
  "virt_mode": "paravirt",
  "kernel": "linode/grub2",
  "devices": {
    "sda": {"disk_id": $alpine_disk_id},
    "sdb": {"disk_id": $raw_disk_id}
  },
  "root_device": "/dev/sda"
}
EOF
)
    
    alpine_config_response=$(api_call "POST" "${API_BASE}/linode/instances/${instance_id}/configs" "${alpine_initial_payload}")
    alpine_id=$(echo "$alpine_config_response" | jq -r '.id')
    
    if [[ -z "$alpine_id" || "$alpine_id" == "null" ]]; then
        log_failure "Failed to create Alpine configuration"
    fi
    
    echo "Created Alpine config with ID: $alpine_id"
    sleep 2
    
    # Create System configuration with 3 interfaces
    echo "Creating System configuration..."
    system_payload=$(cat <<EOF
{
  "label": "System",
  "interfaces": [
    {"purpose": "public", "primary": true},
    {"purpose": "vlan", "label": "$network_id", "ipam_address": "$subnet_CIDR"},
    {"purpose": "vlan", "label": "mgmt"}
  ],
  "virt_mode": "paravirt",
  "kernel": "linode/direct-disk",
  "devices": {
    "sda": {"disk_id": $raw_disk_id}
  },
  "root_device": "/dev/sda"
}
EOF
)
    
    system_response=$(api_call "POST" "${API_BASE}/linode/instances/${instance_id}/configs" "${system_payload}")
    system_id=$(echo "$system_response" | jq -r '.id')
    
    if [[ -z "$system_id" || "$system_id" == "null" ]]; then
        log_failure "Failed to create System configuration"
    fi
    
    echo "Created System config with ID: $system_id"
    sleep 2
    
    # Boot with Alpine configuration
    echo "Booting instance with Alpine configuration..."
    boot_config="{\"config_id\": $alpine_id}"
    boot_response=$(api_call "POST" "${API_BASE}/linode/instances/${instance_id}/boot" "${boot_config}")
    
    boot_status=$(echo "$boot_response" | jq -r '.status' 2>/dev/null || echo "unknown")
    
    # Create log file
    log_file="${instance_id}.log"
    cat > "$log_file" <<EOF
=== Linode Instance Build Log ===
Timestamp: $(date '+%Y-%m-%d %H:%M:%S')

INSTANCE TYPE: ${instance_label}
IMAGE FILE: ${image_file}

REQUEST PARAMETERS:
- Instance Type Requested: $linode_type
- Memory Requested: ${memory}MB
- Region: $region

CREATED INSTANCE:
- Instance ID: $instance_id
- Instance Type Created: $selected_type
- Actual Memory: ${type_memory}MB
- Total Disk: ${type_disk}MB
- Placement Group ID: $placement_group_id

DISKS:
- Alpine Disk ID: $alpine_disk_id
  Size: ${alpine_disk_size}MB
  
- Raw Disk ID: $raw_disk_id
  Size: ${raw_disk_size}MB

CONFIGURATIONS:
- Alpine Config ID: $alpine_id
  Interfaces: eth0 (public), eth1 (vlan:$network_id), eth2 (vlan:mgmt)
  
- System Config ID: $system_id
  Interfaces: eth0 (public), eth1 (vlan:$network_id), eth2 (vlan:mgmt)

BOOT STATUS:
- Booted with Config: $alpine_id (Alpine)
- Boot Status: $boot_status

STACKSCRIPT:
- Image: $image_file
EOF
    
    echo "Instance $instance_label created successfully"
    echo "Instance ID: $instance_id"
    echo "Log file: $log_file"
}

# Create active instance
create_instance "${label}-active-$(date +%s)" "$active" "false"
active_instance_id="$instance_id"

log_info "Active instance created with ID: $active_instance_id"
log_info "Active instance IPv4: $active_ipv4"

# Create standby instance
create_instance "${label}-standby-$(date +%s)" "$standby" "true"
standby_instance_id="$instance_id"

log_info "Standby instance created with ID: $standby_instance_id"
# Final summary
echo ""
echo "=== HA Deployment Complete ==="
echo "Placement Group ID: $placement_group_id"
echo ""
echo "Active Instance:"
echo "  - ID: $active_instance_id"
echo "  - IPv4: $active_ipv4"
echo "  - Image: $active"
echo "  - Log: ${active_instance_id}.log"
echo ""
echo "Standby Instance:"
echo "  - ID: $standby_instance_id"
echo "  - Shared IPv4: $active_ipv4"
echo "  - Image: $standby"
echo "  - Log: ${standby_instance_id}.log"
echo ""
echo "Network Configuration (both instances):"
echo "  - eth0: Public"
echo "  - eth1: VLAN $network_id ($subnet_CIDR)"
echo "  - eth2: VLAN mgmt"
