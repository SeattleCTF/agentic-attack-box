# Common Utilities for aictf

get_my_ip() {
    local ip
    ip=$(curl -s -4 --connect-timeout 5 icanhazip.com || curl -s -4 --connect-timeout 5 ipinfo.io/ip || curl -s -4 --connect-timeout 5 api.ipify.org || true)
    if [ -z "$ip" ]; then
        echo "Error: Could not resolve public IP. Please check your internet connection." >&2
        exit 1
    fi
    echo "$ip" | tr -d '[:space:]'
}

get_config_value() {
    local key="$1"
    local default="${2:-}"
    if [ -f "$CONFIG_FILE" ]; then
        local val
        val=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG_FILE" | head -n 1 | cut -d'=' -f2- | xargs || true)
        if [ -n "$val" ]; then
            echo "$val"
            return
        fi
    fi
    # Non-obvious fallback logic: if looking up AWS_REGION and not configured, query default AWS CLI config
    if [ "$key" = "AWS_REGION" ] && command -v aws &>/dev/null; then
        local profile
        profile=$(get_config_value "AWS_PROFILE" "default")
        local aws_region
        aws_region=$(aws configure get region --profile "$profile" 2>/dev/null || true)
        if [ -n "$aws_region" ]; then
            echo "$aws_region" | tr -d '[:space:]'
            return
        fi
    fi
    echo "$default"
}

set_config_value() {
    local key="$1"
    local val="$2"
    touch "$CONFIG_FILE"
    if grep -q -E "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG_FILE"; then
        local escaped_val=$(echo "$val" | sed 's/[\/&]/\\&/g')
        sed -i -E "s/^([[:space:]]*${key}[[:space:]]*=).*/\1${escaped_val}/" "$CONFIG_FILE"
    else
        echo "${key}=${val}" >> "$CONFIG_FILE"
    fi
}

check_aws_auth() {
    if ! command -v aws &> /dev/null; then
        return 1
    fi
    local profile
    profile=$(get_config_value "AWS_PROFILE" "default")
    if ! aws --profile "$profile" sts get-caller-identity &> /dev/null; then
        return 1
    fi
    return 0
}

select_item() {
    local prompt="$1"
    shift
    local options=("$@")
    
    if [ ${#options[@]} -eq 0 ]; then
        echo ""
        return
    fi
    
    if [ ${#options[@]} -eq 1 ]; then
        echo "${options[0]}"
        return
    fi
    
    if command -v fzf &> /dev/null; then
        printf "%s\n" "${options[@]}" | fzf --prompt="$prompt: "
    else
        echo "$prompt:" >&2
        PS3="Select an option (1-${#options[@]}): "
        # We need to temporarily configure PS3 and run select
        local choice=""
        select opt in "${options[@]}"; do
            if [ -n "$opt" ]; then
                choice="$opt"
                break
            else
                echo "Invalid selection. Please try again." >&2
            fi
        done
        echo "$choice"
    fi
}

generate_ssh_key() {
    local key_file="${SSH_KEYS_DIR}/aictf_key"
    if [ ! -f "$key_file" ]; then
        echo "Generating new SSH keypair..." >&2
        ssh-keygen -t ed25519 -f "$key_file" -N "" -C "aictf-agentic-attack-box" >/dev/null
        chmod 600 "$key_file"
        chmod 644 "${key_file}.pub"
        echo "SSH key generated at $key_file" >&2
        register_resource "ssh-key" "aictf_key" "local" "local" "Path: ${key_file}"
    fi
}

setup_llm_token() {
    local gemini_file="${LLM_KEYS_DIR}/gemini"
    local bedrock_file="${LLM_KEYS_DIR}/bedrock"
    
    # If files exist but are empty, remove them so -s check is clean
    if [ -f "$gemini_file" ] && [ ! -s "$gemini_file" ]; then
        rm -f "$gemini_file"
    fi
    if [ -f "$bedrock_file" ] && [ ! -s "$bedrock_file" ]; then
        rm -f "$bedrock_file"
    fi
    
    if [ ! -s "$gemini_file" ] && [ ! -s "$bedrock_file" ]; then
        echo "No LLM token found in ${LLM_KEYS_DIR}/."
        echo "Crush requires an LLM token to operate."
        echo "Please choose which LLM provider to configure:"
        
        local choice
        choice=$(select_item "Select LLM Provider" "Gemini" "Bedrock")
        
        if [ "$choice" = "Gemini" ]; then
            echo -n "Enter your Gemini API Key: "
            # Disable terminal echoing to prevent token leak
            local gemini_key
            stty -echo
            read -r gemini_key
            stty echo
            echo ""
            if [ -z "$gemini_key" ]; then
                echo "Error: Gemini API Key cannot be empty." >&2
                exit 1
            fi
            echo "$gemini_key" > "$gemini_file"
            chmod 600 "$gemini_file"
            echo "Gemini API key saved to $gemini_file"
            register_resource "llm-token" "gemini" "local" "local" "Path: ${gemini_file}"
        elif [ "$choice" = "Bedrock" ]; then
            echo "Bedrock utilizes AWS IAM credentials. Please enter your AWS credentials if different from your CLI."
            echo -n "Enter AWS Access Key ID / Bearer Token (leave empty to use default AWS profile): "
            local aws_access_key
            read -r aws_access_key
            if [ -n "$aws_access_key" ]; then
                local is_bearer=false
                if [[ "$aws_access_key" == *"bearer"* ]] || [[ "$aws_access_key" == *"Token"* ]] || [[ "$aws_access_key" == *"token"* ]] || [[ ${#aws_access_key} -gt 40 ]]; then
                    is_bearer=true
                fi

                if [ "$is_bearer" = "true" ]; then
                    echo -n "Enter AWS Region (e.g. us-east-1): "
                    local aws_region
                    read -r aws_region
                    aws_region="${aws_region:-us-east-1}"
                    cat <<EOF > "$bedrock_file"
export AWS_BEARER_TOKEN_BEDROCK="$aws_access_key"
export AWS_DEFAULT_REGION="$aws_region"
export AWS_REGION="$aws_region"
EOF
                else
                    echo -n "Enter AWS Secret Access Key: "
                    local aws_secret_key
                    stty -echo
                    read -r aws_secret_key
                    stty echo
                    echo ""
                    echo -n "Enter AWS Region (e.g. us-east-1): "
                    local aws_region
                    read -r aws_region
                    aws_region="${aws_region:-us-east-1}"
                    
                    cat <<EOF > "$bedrock_file"
export AWS_ACCESS_KEY_ID="$aws_access_key"
export AWS_SECRET_ACCESS_KEY="$aws_secret_key"
export AWS_DEFAULT_REGION="$aws_region"
export AWS_REGION="$aws_region"
export AWS_BEARER_TOKEN_BEDROCK="$aws_secret_key"
EOF
                fi
                chmod 600 "$bedrock_file"
                echo "Bedrock configuration saved to $bedrock_file"
                register_resource "llm-token" "bedrock" "local" "local" "Path: ${bedrock_file}"
            else
                echo "Using default AWS profile for Bedrock."
                local profile
                profile=$(get_config_value "AWS_PROFILE" "default")
                
                # Fetch IAM user name to programmatically request a Service Specific Credential
                local iam_user=""
                local resolved_region=""
                
                resolved_region=$(aws configure get region --profile "$profile" 2>/dev/null || echo "us-east-1")
                if [ "$resolved_region" = "None" ] || [ -z "$resolved_region" ]; then
                    resolved_region="us-east-1"
                fi
                
                echo "Attempting to retrieve active IAM user identity..." >&2
                local arn=""
                arn=$(aws sts get-caller-identity --profile "$profile" --query "Arn" --output text 2>/dev/null || true)
                
                if [[ "$arn" == *"user/"* ]]; then
                    # Extract userName from ARN (arn:aws:iam::123456789012:user/UserName)
                    iam_user="${arn##*/}"
                fi
                
                local bearer_token=""
                if [ -n "$iam_user" ]; then
                    echo "Found IAM User: $iam_user" >&2
                    echo "Checking for existing bedrock service-specific credentials..." >&2
                    
                    local existing_creds=""
                    existing_creds=$(aws iam list-service-specific-credentials \
                        --profile "$profile" \
                        --user-name "$iam_user" \
                        --service-name "bedrock.amazonaws.com" \
                        --query "ServiceSpecificCredentials[0].ServiceSpecificCredentialId" \
                        --output text 2>/dev/null || true)
                        
                    if [ -n "$existing_creds" ] && [ "$existing_creds" != "None" ] && [ "$existing_creds" != "null" ]; then
                        echo "Existing Bedrock service credentials found. Generating a new active Bearer Token..." >&2
                        # ServiceSpecificPassword cannot be fetched again, so we'll generate a fresh one
                        # But to prevent credential limits (max 2 per user), we delete the old one first
                        aws iam delete-service-specific-credential \
                            --profile "$profile" \
                            --user-name "$iam_user" \
                            --service-specific-credential-id "$existing_creds" &>/dev/null || true
                    fi
                    
                    echo "Generating standard Bedrock Bearer Token via IAM..." >&2
                    local credential_json=""
                    credential_json=$(aws iam create-service-specific-credential \
                        --profile "$profile" \
                        --user-name "$iam_user" \
                        --service-name "bedrock.amazonaws.com" \
                        --output json 2>/dev/null || true)
                        
                    if [ -n "$credential_json" ]; then
                        bearer_token=$(echo "$credential_json" | jq -r ".ServiceSpecificCredential.ServiceCredentialSecret" 2>/dev/null || echo "")
                        if [ "$bearer_token" = "null" ]; then
                            bearer_token=""
                        fi
                        local cred_id=$(echo "$credential_json" | jq -r ".ServiceSpecificCredential.ServiceSpecificCredentialId" 2>/dev/null || echo "")
                        register_resource "iam-service-credential" "$cred_id" "aws" "global" "User: $iam_user"
                    fi
                fi
                
                if [ -n "$bearer_token" ]; then
                    cat <<EOF > "$bedrock_file"
export AWS_BEARER_TOKEN_BEDROCK="$bearer_token"
export AWS_DEFAULT_REGION="$resolved_region"
export AWS_REGION="$resolved_region"
EOF
                    echo "Successfully generated Bedrock Bearer Token via AWS IAM and saved to $bedrock_file!"
                else
                    echo "Could not programmatically generate Bedrock service-specific credentials (require IAM write permissions)." >&2
                    echo "Falling back to standard profile credentials..." >&2
                    
                    local resolved_key=""
                    local resolved_secret=""
                    local resolved_token=""
                    
                    resolved_key=$(aws configure get aws_access_key_id --profile "$profile" 2>/dev/null || true)
                    resolved_secret=$(aws configure get aws_secret_access_key --profile "$profile" 2>/dev/null || true)
                    resolved_token=$(aws configure get aws_session_token --profile "$profile" 2>/dev/null || true)
                    
                    if [ -z "$resolved_key" ]; then
                        resolved_key="${AWS_ACCESS_KEY_ID:-}"
                        resolved_secret="${AWS_SECRET_ACCESS_KEY:-}"
                        resolved_token="${AWS_SESSION_TOKEN:-}"
                    fi
                    
                    if [ -n "$resolved_key" ] && [ -n "$resolved_secret" ]; then
                        if [ -n "$resolved_token" ]; then
                            cat <<EOF > "$bedrock_file"
export AWS_BEARER_TOKEN_BEDROCK="$resolved_token"
export AWS_DEFAULT_REGION="$resolved_region"
export AWS_REGION="$resolved_region"
EOF
                        else
                            cat <<EOF > "$bedrock_file"
export AWS_BEARER_TOKEN_BEDROCK="$resolved_secret"
export AWS_DEFAULT_REGION="$resolved_region"
export AWS_REGION="$resolved_region"
EOF
                        fi
                        echo "Bedrock keys successfully resolved from AWS profile '$profile' and saved as Bearer Token."
                    else
                        echo "Warning: Could not automatically resolve static AWS credentials from profile '$profile'."
                        echo "An empty credentials file has been created. Bedrock access on the remote box may require manual configuration."
                        touch "$bedrock_file"
                    fi
                fi
                chmod 600 "$bedrock_file"
                register_resource "llm-token" "bedrock" "local" "local" "Path: ${bedrock_file}"
            fi
        else
            echo "Aborted LLM token setup." >&2
            exit 1
        fi
    fi
}

register_resource() {
    local r_type="$1"
    local r_id="$2"
    local r_provider="$3"
    local r_region="$4"
    local r_meta="$5"

    touch "$RESOURCES_FILE"
    # Prevent duplicate entries by removing any existing entry with same type, id, provider, region
    deregister_resource "$r_type" "$r_id" "$r_provider" "$r_region"

    echo "${r_type} | ${r_id} | ${r_provider} | ${r_region} | ${r_meta}" >> "$RESOURCES_FILE"
}

deregister_resource() {
    local r_type="$1"
    local r_id="$2"
    local r_provider="$3"
    local r_region="$4"

    if [ -f "$RESOURCES_FILE" ]; then
        local tmp=$(mktemp)
        # Filter out the matching resource line (exact/whitespace tolerant matching of parts)
        grep -v -E "^[[:space:]]*${r_type}[[:space:]]*\|[[:space:]]*${r_id}[[:space:]]*\|[[:space:]]*${r_provider}[[:space:]]*\|[[:space:]]*${r_region}" "$RESOURCES_FILE" > "$tmp" || true
        mv "$tmp" "$RESOURCES_FILE"
    fi
}

ensure_network_env() {
    local profile="$1"
    local region="$2"

    local default_vpc_id
    default_vpc_id=$(aws ec2 describe-vpcs \
        --profile "$profile" \
        --region "$region" \
        --filters "Name=isDefault,Values=true" \
        --query "Vpcs[0].VpcId" \
        --output text 2>/dev/null || echo "None")

    if [ -n "$default_vpc_id" ] && [ "$default_vpc_id" != "None" ] && [ "$default_vpc_id" != "null" ]; then
        # Default VPC exists
        echo -e "${C_FLAG}Using default VPC:${C_RESET} ${C_SUBCOMMAND}$default_vpc_id${C_RESET}" >&2
        local default_subnet_id
        default_subnet_id=$(aws ec2 describe-subnets \
            --profile "$profile" \
            --region "$region" \
            --filters "Name=vpc-id,Values=$default_vpc_id" \
            --query "Subnets[0].SubnetId" \
            --output text 2>/dev/null || echo "None")
        if [ -n "$default_subnet_id" ] && [ "$default_subnet_id" != "None" ] && [ "$default_subnet_id" != "null" ]; then
            echo "$default_vpc_id|$default_subnet_id"
            return
        fi
    fi

    # No default VPC (or no default subnets). Ensure custom aictf VPC environment.
    echo -e "${C_SUBCOMMAND}No default VPC found in region $region. Ensuring custom aictf VPC is configured...${C_RESET}" >&2

    local aictf_vpc_id
    aictf_vpc_id=$(aws ec2 describe-vpcs \
        --profile "$profile" \
        --region "$region" \
        --filters "Name=tag:CreatedBy,Values=aictf" \
        --query "Vpcs[0].VpcId" \
        --output text 2>/dev/null || echo "None")

    if [ -z "$aictf_vpc_id" ] || [ "$aictf_vpc_id" = "None" ] || [ "$aictf_vpc_id" = "null" ]; then
        echo -e "${C_FLAG}Creating aictf custom VPC...${C_RESET}" >&2
        aictf_vpc_id=$(aws ec2 create-vpc \
            --profile "$profile" \
            --region "$region" \
            --cidr-block "10.0.0.0/16" \
            --tag-specifications "ResourceType=vpc,Tags=[{Key=CreatedBy,Value=aictf},{Key=Name,Value=aictf-vpc}]" \
            --query "Vpc.VpcId" \
            --output text)
        register_resource "vpc" "$aictf_vpc_id" "aws" "$region" "Cidr: 10.0.0.0/16"
        
        # Enable DNS hostnames and support
        aws ec2 modify-vpc-attribute --profile "$profile" --region "$region" --vpc-id "$aictf_vpc_id" --enable-dns-hostnames "{\"Value\":true}" >/dev/null
        aws ec2 modify-vpc-attribute --profile "$profile" --region "$region" --vpc-id "$aictf_vpc_id" --enable-dns-support "{\"Value\":true}" >/dev/null
    fi

    local aictf_subnet_id
    aictf_subnet_id=$(aws ec2 describe-subnets \
        --profile "$profile" \
        --region "$region" \
        --filters "Name=vpc-id,Values=$aictf_vpc_id" "Name=tag:CreatedBy,Values=aictf" \
        --query "Subnets[0].SubnetId" \
        --output text 2>/dev/null || echo "None")

    if [ -z "$aictf_subnet_id" ] || [ "$aictf_subnet_id" = "None" ] || [ "$aictf_subnet_id" = "null" ]; then
        echo -e "${C_FLAG}Creating aictf custom subnet...${C_RESET}" >&2
        aictf_subnet_id=$(aws ec2 create-subnet \
            --profile "$profile" \
            --region "$region" \
            --vpc-id "$aictf_vpc_id" \
            --cidr-block "10.0.1.0/24" \
            --tag-specifications "ResourceType=subnet,Tags=[{Key=CreatedBy,Value=aictf},{Key=Name,Value=aictf-subnet}]" \
            --query "Subnet.SubnetId" \
            --output text)
        register_resource "subnet" "$aictf_subnet_id" "aws" "$region" "Vpc: ${aictf_vpc_id}"
        
        # Auto-assign public IPs
        aws ec2 modify-subnet-attribute --profile "$profile" --region "$region" --subnet-id "$aictf_subnet_id" --map-public-ip-on-launch "{\"Value\":true}" >/dev/null
    fi

    local aictf_igw_id
    aictf_igw_id=$(aws ec2 describe-internet-gateways \
        --profile "$profile" \
        --region "$region" \
        --filters "Name=attachment.vpc-id,Values=$aictf_vpc_id" \
        --query "InternetGateways[0].InternetGatewayId" \
        --output text 2>/dev/null || echo "None")

    if [ -z "$aictf_igw_id" ] || [ "$aictf_igw_id" = "None" ] || [ "$aictf_igw_id" = "null" ]; then
        # Check if detached aictf igw exists
        aictf_igw_id=$(aws ec2 describe-internet-gateways \
            --profile "$profile" \
            --region "$region" \
            --filters "Name=tag:CreatedBy,Values=aictf" \
            --query "InternetGateways[0].InternetGatewayId" \
            --output text 2>/dev/null || echo "None")

        if [ -z "$aictf_igw_id" ] || [ "$aictf_igw_id" = "None" ] || [ "$aictf_igw_id" = "null" ]; then
            echo -e "${C_FLAG}Creating custom internet gateway...${C_RESET}" >&2
            aictf_igw_id=$(aws ec2 create-internet-gateway \
                --profile "$profile" \
                --region "$region" \
                --tag-specifications "ResourceType=internet-gateway,Tags=[{Key=CreatedBy,Value=aictf},{Key=Name,Value=aictf-igw}]" \
                --query "InternetGateway.InternetGatewayId" \
                --output text)
            register_resource "internet-gateway" "$aictf_igw_id" "aws" "$region" "Created"
        fi
        
        echo -e "${C_MUTED}Attaching internet gateway to VPC...${C_RESET}" >&2
        aws ec2 attach-internet-gateway \
            --profile "$profile" \
            --region "$region" \
            --vpc-id "$aictf_vpc_id" \
            --internet-gateway-id "$aictf_igw_id" >/dev/null
    fi

    local aictf_rt_id
    aictf_rt_id=$(aws ec2 describe-route-tables \
        --profile "$profile" \
        --region "$region" \
        --filters "Name=vpc-id,Values=$aictf_vpc_id" \
        --query "RouteTables[0].RouteTableId" \
        --output text 2>/dev/null || echo "None")

    if [ -n "$aictf_rt_id" ] && [ "$aictf_rt_id" != "None" ] && [ "$aictf_rt_id" != "null" ]; then
        # Check if route to 0.0.0.0/0 exists
        local has_route
        has_route=$(aws ec2 describe-route-tables \
            --profile "$profile" \
            --region "$region" \
            --route-table-ids "$aictf_rt_id" \
            --query "RouteTables[0].Routes[?DestinationCidrBlock=='0.0.0.0/0'].GatewayId" \
            --output text 2>/dev/null || echo "None")
        if [ -z "$has_route" ] || [ "$has_route" = "None" ] || [ "$has_route" = "null" ]; then
            echo -e "${C_MUTED}Adding route to Internet Gateway...${C_RESET}" >&2
            aws ec2 create-route \
                --profile "$profile" \
                --region "$region" \
                --route-table-id "$aictf_rt_id" \
                --destination-cidr-block "0.0.0.0/0" \
                --gateway-id "$aictf_igw_id" >/dev/null || true
        fi
        
        # Associate RT with Subnet
        aws ec2 associate-route-table \
            --profile "$profile" \
            --region "$region" \
            --subnet-id "$aictf_subnet_id" \
            --route-table-id "$aictf_rt_id" &>/dev/null || true
    fi

    echo "$aictf_vpc_id|$aictf_subnet_id"
}
