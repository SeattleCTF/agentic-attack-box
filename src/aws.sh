# AWS Provider Subroutines

get_active_instances() {
    local profile=$(get_config_value "AWS_PROFILE" "default")
    local region=$(get_config_value "AWS_REGION" "us-east-1")
    aws ec2 describe-instances \
        --profile "$profile" \
        --region "$region" \
        --filters "Name=tag:CreatedBy,Values=aictf" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[*].Instances[*].[InstanceId, State.Name, PublicIpAddress]' \
        --output text 2>/dev/null || echo ""
}

select_aws_instance() {
    local target_id="${1:-}"
    if [ -n "$target_id" ]; then
        echo "$target_id"
        return
    fi
    
    local instances_raw=$(get_active_instances)
    if [ -z "$instances_raw" ]; then
        echo "Error: No managed AWS instances found." >&2
        exit 1
    fi
    
    # Read into lines
    local lines=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            lines+=("$line")
        fi
    done <<< "$instances_raw"
    
    if [ ${#lines[@]} -eq 0 ]; then
        echo "Error: No managed AWS instances found." >&2
        exit 1
    fi
    
    if [ ${#lines[@]} -eq 1 ]; then
        echo "${lines[0]}" | awk '{print $1}'
        return
    fi
    
    local options=()
    for line in "${lines[@]}"; do
        local id=$(echo "$line" | awk '{print $1}')
        local state=$(echo "$line" | awk '{print $2}')
        local ip=$(echo "$line" | awk '{print $3}')
        options+=("$id ($state - $ip)")
    done
    
    local selected=$(select_item "Select an AWS instance" "${options[@]}")
    if [ -z "$selected" ]; then
        echo "No instance selected." >&2
        exit 1
    fi
    
    echo "$selected" | awk '{print $1}'
}

cmd_aws_shell() {
    local instance_id=$(select_aws_instance "${1:-}")
    
    local profile=$(get_config_value "AWS_PROFILE" "default")
    local region=$(get_config_value "AWS_REGION" "us-east-1")
    
    local inst_details=$(aws ec2 describe-instances \
        --profile "$profile" \
        --region "$region" \
        --instance-ids "$instance_id" \
        --query "Reservations[0].Instances[0].{State:State.Name,PublicIp:PublicIpAddress,ImageId:ImageId}" \
        --output json 2>/dev/null)
        
    local state=$(echo "$inst_details" | jq -r '.State' 2>/dev/null || echo "")
    local public_ip=$(echo "$inst_details" | jq -r '.PublicIp' 2>/dev/null || echo "")
    local image_id=$(echo "$inst_details" | jq -r '.ImageId' 2>/dev/null || echo "")
    
    if [ "$state" != "running" ]; then
        echo "Error: Instance $instance_id is not running (Current state: $state)." >&2
        echo "Please start the instance first: aictf aws start $instance_id" >&2
        exit 1
    fi
    
    if [ "$public_ip" = "null" ] || [ -z "$public_ip" ]; then
        echo "Error: Instance $instance_id does not have a public IP address." >&2
        exit 1
    fi
    
    local ami_name=$(aws ec2 describe-images --profile "$profile" --region "$region" --image-ids "$image_id" --query "Images[0].Name" --output text 2>/dev/null || echo "")
    local ssh_user="admin"
    if [[ "$ami_name" == *"kali"* ]]; then
        ssh_user="kali"
    fi
    
    local my_ip=$(get_my_ip)
    local whitelisted=false
    
    local sgs=$(aws ec2 describe-instances \
        --profile "$profile" \
        --region "$region" \
        --instance-ids "$instance_id" \
        --query "Reservations[0].Instances[0].SecurityGroups[].GroupId" \
        --output text)
        
    for sg_id in $sgs; do
        local cidrs=$(aws ec2 describe-security-groups --profile "$profile" --region "$region" --group-ids "$sg_id" --query "SecurityGroups[0].IpPermissions[?ToPort==\`22\`].IpRanges[].CidrIp" --output text 2>/dev/null || true)
        if echo "$cidrs" | grep -q -E "(${my_ip}/32|0\.0\.0\.0/0)"; then
            whitelisted=true
            break
        fi
    done
    
    if [ "$whitelisted" = "false" ]; then
        echo -e "${C_SUBCOMMAND}Instance is not accessible from your current IP ($my_ip).${C_RESET}" >&2
        echo -e "${C_MUTED}Automatically running 'aictf aws access' to whitelist your IP...${C_RESET}" >&2
        cmd_aws_access "$instance_id"
    fi
    
    local key_file="${SSH_KEYS_DIR}/aictf_key"
    echo -e "${C_FLAG}Connecting to ${ssh_user}@${public_ip}...${C_RESET}"
    ssh -i "$key_file" -o StrictHostKeyChecking=no "${ssh_user}@${public_ip}"
}

cmd_aws_start() {
    local instance_id=$(select_aws_instance "${1:-}")
    local profile=$(get_config_value "AWS_PROFILE" "default")
    local region=$(get_config_value "AWS_REGION" "us-east-1")
    
    echo -e "${C_FLAG}Starting instance $instance_id...${C_RESET}"
    aws ec2 start-instances --profile "$profile" --region "$region" --instance-ids "$instance_id" >/dev/null
    echo -e "${C_FLAG}Success:${C_RESET} ${C_TEXT}Instance start request submitted. It may take a minute to boot.${C_RESET}"
}

cmd_aws_stop() {
    local instance_id=$(select_aws_instance "${1:-}")
    local profile=$(get_config_value "AWS_PROFILE" "default")
    local region=$(get_config_value "AWS_REGION" "us-east-1")
    
    echo -e "${C_FLAG}Stopping instance $instance_id...${C_RESET}"
    aws ec2 stop-instances --profile "$profile" --region "$region" --instance-ids "$instance_id" >/dev/null
    echo -e "${C_FLAG}Success:${C_RESET} ${C_TEXT}Instance stop request submitted.${C_RESET}"
}

cmd_aws_destroy() {
    local instance_id=$(select_aws_instance "${1:-}")
    local profile=$(get_config_value "AWS_PROFILE" "default")
    local region=$(get_config_value "AWS_REGION" "us-east-1")
    
    echo -e -n "${C_SUBCOMMAND}Are you sure you want to destroy instance ${instance_id}? [y/N]: ${C_RESET}"
    local confirmation
    read -r confirmation
    if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
        echo -e "${C_MUTED}Termination aborted.${C_RESET}"
        return 0
    fi
    
    echo -e "${C_SUBCOMMAND}Terminating instance $instance_id...${C_RESET}"
    aws ec2 terminate-instances --profile "$profile" --region "$region" --instance-ids "$instance_id" >/dev/null
    deregister_resource "instance" "$instance_id" "aws" "$region"
    echo -e "${C_FLAG}Success:${C_RESET} ${C_TEXT}Instance termination request submitted.${C_RESET}"
}

cmd_aws_access() {
    local instance_id=$(select_aws_instance "${1:-}")
    local profile=$(get_config_value "AWS_PROFILE" "default")
    local region=$(get_config_value "AWS_REGION" "us-east-1")
    local my_ip=$(get_my_ip)
    
    local sg_id=$(aws ec2 describe-instances \
        --profile "$profile" \
        --region "$region" \
        --instance-ids "$instance_id" \
        --query "Reservations[0].Instances[0].SecurityGroups[0].GroupId" \
        --output text)
        
    if [ -z "$sg_id" ] || [ "$sg_id" = "None" ]; then
        echo -e "${C_SUBCOMMAND}Error: Could not find security group for instance $instance_id.${C_RESET}" >&2
        exit 1
    fi
    
    echo -e "${C_FLAG}Updating Security Group $sg_id to authorize port 22 ingress for $my_ip/32...${C_RESET}"
    
    local existing_rules=$(aws ec2 describe-security-groups \
        --profile "$profile" \
        --region "$region" \
        --group-ids "$sg_id" \
        --query "SecurityGroups[0].IpPermissions[?ToPort==\`22\`].IpRanges[].CidrIp" \
        --output text)
        
    for cidr in $existing_rules; do
        if [ -n "$cidr" ] && [ "$cidr" != "None" ]; then
            echo -e "${C_MUTED}Revoking existing ingress rule for $cidr...${C_RESET}"
            aws ec2 revoke-security-group-ingress \
                --profile "$profile" \
                --region "$region" \
                --group-id "$sg_id" \
                --protocol tcp \
                --port 22 \
                --cidr "$cidr" &>/dev/null || true
        fi
    done
    
    aws ec2 authorize-security-group-ingress \
        --profile "$profile" \
        --region "$region" \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 22 \
        --cidr "${my_ip}/32"
        
    echo "Security group updated successfully. Exclusive access granted to $my_ip."
}

cmd_aws_sync_creds() {
    local profile=$(get_config_value "AWS_PROFILE" "default")
    local region=$(get_config_value "AWS_REGION" "us-east-1")
    
    local bedrock_file="${LLM_KEYS_DIR}/bedrock"
    local gemini_file="${LLM_KEYS_DIR}/gemini"
    
    # 1. Run setup token to prompt or dynamically resolve credentials
    setup_llm_token
    
    local llm_env_setup=""
    if [ -f "$gemini_file" ] && [ -s "$gemini_file" ]; then
        local gemini_val=$(cat "$gemini_file")
        llm_env_setup="export GEMINI_API_KEY='${gemini_val}'"
    elif [ -f "$bedrock_file" ] && [ -s "$bedrock_file" ]; then
        llm_env_setup=$(cat "$bedrock_file")
    else
        echo -e "${C_SUBCOMMAND}Error: No valid LLM credentials found to sync.${C_RESET}" >&2
        exit 1
    fi
    
    # 2. Get active instances
    local instances_raw=$(get_active_instances)
    if [ -z "$instances_raw" ]; then
        echo -e "${C_SUBCOMMAND}No active AWS instances found to sync credentials.${C_RESET}"
        return 0
    fi
    
    local lines=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            lines+=("$line")
        fi
    done <<< "$instances_raw"
    
    echo -e "${C_FLAG}Found ${#lines[@]} instance(s) in region $region. Syncing credentials via SSH...${C_RESET}"
    
    for line in "${lines[@]}"; do
        local inst_id=$(echo "$line" | awk '{print $1}')
        local state=$(echo "$line" | awk '{print $2}')
        local public_ip=$(echo "$line" | awk '{print $3}')
        
        if [ "$state" != "running" ]; then
            echo -e "${C_MUTED}Skipping instance $inst_id because it is in state: $state${C_RESET}"
            continue
        fi
        
        if [ "$public_ip" = "None" ] || [ -z "$public_ip" ] || [ "$public_ip" = "null" ]; then
            echo -e "${C_MUTED}Skipping instance $inst_id because it does not have a public IP address.${C_RESET}"
            continue
        fi
        
        # Determine image and default user
        local image_id=$(aws ec2 describe-instances \
            --profile "$profile" \
            --region "$region" \
            --instance-ids "$inst_id" \
            --query "Reservations[0].Instances[0].ImageId" \
            --output text 2>/dev/null || echo "")
            
        local ami_name=$(aws ec2 describe-images --profile "$profile" --region "$region" --image-ids "$image_id" --query "Images[0].Name" --output text 2>/dev/null || echo "")
        local ssh_user="admin"
        if [[ "$ami_name" == *"kali"* ]]; then
            ssh_user="kali"
        fi
        
        echo -e "${C_TEXT}Syncing credentials to ${C_SUBCOMMAND}$inst_id${C_RESET} (${C_FLAG}$public_ip${C_RESET}) as user '${C_PRIMARY}$ssh_user${C_RESET}'...${C_RESET}"
        
        local key_file="${SSH_KEYS_DIR}/aictf_key"
        
        # Ensure Security Group whitelists current IP for connection
        local whitelisted=false
        local sgs=$(aws ec2 describe-instances \
            --profile "$profile" \
            --region "$region" \
            --instance-ids "$inst_id" \
            --query "Reservations[0].Instances[0].SecurityGroups[].GroupId" \
            --output text)
            
        local my_ip=$(get_my_ip)
        for sg_id in $sgs; do
            local cidrs=$(aws ec2 describe-security-groups --profile "$profile" --region "$region" --group-ids "$sg_id" --query "SecurityGroups[0].IpPermissions[?ToPort==\`22\`].IpRanges[].CidrIp" --output text 2>/dev/null || true)
            if echo "$cidrs" | grep -q -E "(${my_ip}/32|0\.0\.0\.0/0)"; then
                whitelisted=true
                break
            fi
        done
        
        if [ "$whitelisted" = "false" ]; then
            echo -e "${C_MUTED}Access not open. Auto-whitelisting your IP in security group...${C_RESET}" >&2
            cmd_aws_access "$inst_id"
        fi
        
        # Prepare remote commands to safely update /etc/environment and profiles
        ssh -i "$key_file" -o StrictHostKeyChecking=no "${ssh_user}@${public_ip}" bash -s <<SSH_EOF
set -euo pipefail

echo "Updating shell configurations..."
# Clear old lines if any exist
sed -i '/GEMINI_API_KEY/d' ~/.bashrc ~/.profile 2>/dev/null || true
sed -i '/AWS_ACCESS_KEY_ID/d' ~/.bashrc ~/.profile 2>/dev/null || true
sed -i '/AWS_SECRET_ACCESS_KEY/d' ~/.bashrc ~/.profile 2>/dev/null || true
sed -i '/AWS_DEFAULT_REGION/d' ~/.bashrc ~/.profile 2>/dev/null || true
sed -i '/AWS_SESSION_TOKEN/d' ~/.bashrc ~/.profile 2>/dev/null || true
sed -i '/AWS_BEARER_TOKEN_BEDROCK/d' ~/.bashrc ~/.profile 2>/dev/null || true
sed -i '/AWS_REGION/d' ~/.bashrc ~/.profile 2>/dev/null || true

# Append new credentials
echo "$llm_env_setup" >> ~/.bashrc
echo "$llm_env_setup" >> ~/.profile

echo "Updating system-wide environments..."
# Safely update /etc/environment (requires sudo, if passwordless sudo is configured on attack boxes)
if sudo -n true 2>/dev/null; then
    sudo sed -i '/GEMINI_API_KEY/d' /etc/environment
    sudo sed -i '/AWS_ACCESS_KEY_ID/d' /etc/environment
    sudo sed -i '/AWS_SECRET_ACCESS_KEY/d' /etc/environment
    sudo sed -i '/AWS_DEFAULT_REGION/d' /etc/environment
    sudo sed -i '/AWS_SESSION_TOKEN/d' /etc/environment
    sudo sed -i '/AWS_BEARER_TOKEN_BEDROCK/d' /etc/environment
    sudo sed -i '/AWS_REGION/d' /etc/environment
    
    while read -r line; do
        if [ -n "\$line" ]; then
            echo "\$line" | sudo tee -a /etc/environment >/dev/null
        fi
    done << 'ENV_INNER_EOF'
$llm_env_setup
ENV_INNER_EOF
fi

echo "Credentials synced successfully."
SSH_EOF

    done
    echo -e "${C_FLAG}Credential sync complete.${C_RESET}"
}

cmd_aws_sync_skills() {
    local profile=$(get_config_value "AWS_PROFILE" "default")
    local region=$(get_config_value "AWS_REGION" "us-east-1")
    
    local instances_raw=$(get_active_instances)
    if [ -z "$instances_raw" ]; then
        echo -e "${C_SUBCOMMAND}No active AWS instances found to sync skills.${C_RESET}"
        return 0
    fi
    
    local lines=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            lines+=("$line")
        fi
    done <<< "$instances_raw"
    
    echo -e "${C_FLAG}Found ${#lines[@]} instance(s) in region $region. Syncing agent skills via SSH...${C_RESET}"
    
    for line in "${lines[@]}"; do
        local inst_id=$(echo "$line" | awk '{print $1}')
        local state=$(echo "$line" | awk '{print $2}')
        local public_ip=$(echo "$line" | awk '{print $3}')
        
        if [ "$state" != "running" ]; then
            echo -e "${C_MUTED}Skipping instance $inst_id because it is in state: $state${C_RESET}"
            continue
        fi
        
        if [ "$public_ip" = "None" ] || [ -z "$public_ip" ] || [ "$public_ip" = "null" ]; then
            echo -e "${C_MUTED}Skipping instance $inst_id because it does not have a public IP address.${C_RESET}"
            continue
        fi
        
        # Determine image and default user
        local image_id=$(aws ec2 describe-instances \
            --profile "$profile" \
            --region "$region" \
            --instance-ids "$inst_id" \
            --query "Reservations[0].Instances[0].ImageId" \
            --output text 2>/dev/null || echo "")
            
        local ami_name=$(aws ec2 describe-images --profile "$profile" --region "$region" --image-ids "$image_id" --query "Images[0].Name" --output text 2>/dev/null || echo "")
        local ssh_user="admin"
        if [[ "$ami_name" == *"kali"* ]]; then
            ssh_user="kali"
        fi
        
        echo -e "${C_TEXT}Syncing skills to ${C_SUBCOMMAND}$inst_id${C_RESET} (${C_FLAG}$public_ip${C_RESET}) as user '${C_PRIMARY}$ssh_user${C_RESET}'...${C_RESET}"
        
        local key_file="${SSH_KEYS_DIR}/aictf_key"
        
        # Ensure Security Group whitelists current IP for connection
        local whitelisted=false
        local sgs=$(aws ec2 describe-instances \
            --profile "$profile" \
            --region "$region" \
            --instance-ids "$inst_id" \
            --query "Reservations[0].Instances[0].SecurityGroups[].GroupId" \
            --output text)
            
        local my_ip=$(get_my_ip)
        for sg_id in $sgs; do
            local cidrs=$(aws ec2 describe-security-groups --profile "$profile" --region "$region" --group-ids "$sg_id" --query "SecurityGroups[0].IpPermissions[?ToPort==\`22\`].IpRanges[].CidrIp" --output text 2>/dev/null || true)
            if echo "$cidrs" | grep -q -E "(${my_ip}/32|0\.0\.0\.0/0)"; then
                whitelisted=true
                break
            fi
        done
        
        if [ "$whitelisted" = "false" ]; then
            echo -e "${C_MUTED}Access not open. Auto-whitelisting your IP in security group...${C_RESET}" >&2
            cmd_aws_access "$inst_id"
        fi
        
        # Sync all local skills from skills/ directory on host using inline transfer
        # This allows users to easily add/edit skills locally and sync them via sync-skills
        # Penderrin2004 Edit
        if [ -d "$AICTF_CODE_DIR/skills" ]; then
            for skill_path in $AICTF_CODE_DIR/skills/*; do
                if [ -d "$skill_path" ]; then
                    local skill_name=$(basename "$skill_path")
                    local skill_content=$(cat "$skill_path/SKILL.md")
                    
                    ssh -i "$key_file" -o StrictHostKeyChecking=no "${ssh_user}@${public_ip}" bash -s <<SSH_EOF
set -euo pipefail
USER_HOME=\$HOME
mkdir -p "\${USER_HOME}/.agents/skills/${skill_name}"
cat << 'SKILL_INNER_EOF' > "\${USER_HOME}/.agents/skills/${skill_name}/SKILL.md"
$skill_content
SKILL_INNER_EOF
chown -R \$(whoami):\$(whoami) "\${USER_HOME}/.agents"
SSH_EOF
                fi
            done
        else
            # Default fallback if skills/ folder is missing on host
            ssh -i "$key_file" -o StrictHostKeyChecking=no "${ssh_user}@${public_ip}" bash -s <<'SSH_EOF'
set -euo pipefail

USER_HOME=$HOME
mkdir -p "${USER_HOME}/.agents/skills/htb-web/"

cat << 'SKILL_INNER_EOF' > "${USER_HOME}/.agents/skills/htb-web/SKILL.md"
# Skill: htb-web (HackTheBox Web Challenge Assistant)

## Description
This skill is designed for enumerating, exploiting, and documenting web-based CTF challenges in HackTheBox and other security platforms. It guides the user conceptually through web vulnerabilities, executes required tool commands, and formats a clean, comprehensive penetration testing report/writeup of the challenge.

## Workflow
1. **Target Verification**: Check if a target IP address or hostname is provided in the prompt. If not, immediately stop and ask: "What is the target IP address?" Do not proceed until provided.
2. **Enumeration Phase**: Suggest and execute (with user permission) these standard enumeration commands:
   - `nmap -p 80,443 -sC -sV <target_ip>`
   - `gobuster dir -u http://<target_ip> -w /usr/share/seclists/Discovery/Web-Content/common.txt`
   - `ffuf -w /usr/share/seclists/Discovery/Web-Content/common.txt -u http://<target_ip>/FUZZ`
3. **Exploitation Phase**: Conceptually explain any discovered vulnerability (SQLi, LFI, SSRF, XSS, etc.) to act as a mentor. Explain exactly why the exploit payload works before running it. Provide a short one-line description of what each step of the exploit is doing.

## Writeup Template
Upon successful exploitation or challenge completion, generate an educational writeup following this exact markdown template:

# HackTheBox Web Challenge Writeup

## 1. Executive Summary
- **Challenge Name**: [Challenge Name]
- **Difficulty**: [Easy/Medium/Hard]
- **Target IP**: [Target IP]
- **Summary**: Concise overview of the vulnerability and impact.

## 2. Enumeration
Describe the discovery steps (ports, endpoints found, gobuster outputs, etc.).

## 3. Vulnerability Explanation
Detail the discovered vulnerability conceptually. Explain the underlying flaw and why it exists.

## 4. Exploitation
Provide the step-by-step exploit payloads with a one-line description for why each is needed.

## 5. Remediation
Actionable advice on how developers should patch and secure this specific vulnerability.
SKILL_INNER_EOF

# Set proper ownership for current ssh user
chown -R $(whoami):$(whoami) "${USER_HOME}/.agents"
echo "Skills synced successfully."
SSH_EOF
        fi

    done
    echo -e "${C_FLAG}Skill sync complete.${C_RESET}"
}

cmd_aws_usage() {
    local timeframe=""
    
    # Process optional parameters
    while [ $# -gt 0 ]; do
        case "$1" in
            --timeframe)
                timeframe="${2:-}"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    local profile=$(get_config_value "AWS_PROFILE" "default")
    local region=$(get_config_value "AWS_REGION" "us-east-1")

    # Initialize variables for Python aggregation
    local hour_ec2_hours="0.0"
    local hour_ec2_cost="0.0"
    local hour_bedrock_tokens="0"
    local hour_bedrock_cost="0.0"

    # 1. Parse local ~/.aictf/usage.log and ~/.aictf/resources for "Last Hour" stats
    local now_epoch=$(date +%s)
    local one_hour_ago=$((now_epoch - 3600))

    if [ -f "$USAGE_LOG_FILE" ]; then
        # Aggregate active instances starting/running in the last hour
        local active_count=$(grep -E "REGISTER[[:space:]]*\|[[:space:]]*instance" "$RESOURCES_FILE" | wc -l || echo "0")
        active_count=$(echo "$active_count" | tr -d '[:space:]')
        if [ "$active_count" -gt 0 ]; then
            # If we have active instances, assume they have been running this hour
            hour_ec2_hours=$(echo "scale=2; $active_count * 1.0" | bc || echo "1.0")
            hour_ec2_cost=$(echo "scale=4; $hour_ec2_hours * 0.0116" | bc || echo "0.01") # t2.micro cost is roughly $0.0116/hr
        fi

        # Extract Bedrock token usage from logged resources/usage tags in the last 60 minutes
        # We assume logged tokens look like: "<timestamp> | TOKEN_USE | <token_count> | <cost>"
        while IFS='|' read -r timestamp action details_1 details_2 details_3; do
            if [ -n "$timestamp" ]; then
                local t_epoch=$(echo "$timestamp" | tr -d '[:space:]' | xargs)
                if [[ "$t_epoch" =~ ^[0-9]+$ ]] && [ "$t_epoch" -ge "$one_hour_ago" ]; then
                    local act=$(echo "$action" | tr -d '[:space:]')
                    if [ "$act" = "TOKEN_USE" ]; then
                        local t_cnt=$(echo "$details_1" | tr -d '[:space:]' | xargs)
                        local t_cst=$(echo "$details_2" | tr -d '[:space:]' | xargs)
                        hour_bedrock_tokens=$((hour_bedrock_tokens + t_cnt))
                        hour_bedrock_cost=$(echo "scale=4; $hour_bedrock_cost + $t_cst" | bc || echo "0.00")
                    fi
                fi
            fi
        done < "$USAGE_LOG_FILE" 2>/dev/null || true
    fi

    # 2. Query AWS Cost Explorer for Last Day, Last Week, Last Month
    # Default outputs if CE fails
    local ce_day_ec2="0.00" ce_day_bedrock="0.00" ce_day_bedrock_tok="0"
    local ce_week_ec2="0.00" ce_week_bedrock="0.00" ce_week_bedrock_tok="0"
    local ce_month_ec2="0.00" ce_month_bedrock="0.00" ce_month_bedrock_tok="0"
    
    local ce_enabled=true

    # Build dates for CE
    local today=$(date +%Y-%m-%d)
    local yesterday=$(date -d "1 day ago" +%Y-%m-%d 2>/dev/null || date -v-1d +%Y-%m-%d 2>/dev/null || echo "")
    local seven_days_ago=$(date -d "7 days ago" +%Y-%m-%d 2>/dev/null || date -v-7d +%Y-%m-%d 2>/dev/null || echo "")
    local thirty_days_ago=$(date -d "30 days ago" +%Y-%m-%d 2>/dev/null || date -v-30d +%Y-%m-%d 2>/dev/null || echo "")

    if [ -n "$yesterday" ] && command -v aws &>/dev/null; then
        # Test AWS CE capability silently first before printing message
        local test_err
        if test_err=$(aws ce get-cost-and-usage \
            --profile "$profile" \
            --region "us-east-1" \
            --time-period Start="$yesterday",End="$today" \
            --granularity "DAILY" \
            --metrics "UnblendedCost" 2>&1); then
            
            echo -e "${C_MUTED}Fetching usage stats from AWS Cost Explorer...${C_RESET}" >&2
            
            # Query last 24h
            local day_res
            day_res=$(aws ce get-cost-and-usage \
                --profile "$profile" \
                --region "us-east-1" \
                --time-period Start="$yesterday",End="$today" \
                --granularity "DAILY" \
                --metrics "UnblendedCost" "UsageQuantity" \
                --filter '{"Dimensions": {"Key": "SERVICE", "Values": ["Amazon Elastic Compute Cloud - Compute", "Amazon Bedrock"]}}' \
                --group-by '[{"Type": "DIMENSION", "Key": "SERVICE"}]' \
                --output json 2>/dev/null || echo "{}")

            # Query last 7 days
            local week_res
            week_res=$(aws ce get-cost-and-usage \
                --profile "$profile" \
                --region "us-east-1" \
                --time-period Start="$seven_days_ago",End="$today" \
                --granularity "MONTHLY" \
                --metrics "UnblendedCost" "UsageQuantity" \
                --filter '{"Dimensions": {"Key": "SERVICE", "Values": ["Amazon Elastic Compute Cloud - Compute", "Amazon Bedrock"]}}' \
                --group-by '[{"Type": "DIMENSION", "Key": "SERVICE"}]' \
                --output json 2>/dev/null || echo "{}")

            # Query last 30 days
            local month_res
            month_res=$(aws ce get-cost-and-usage \
                --profile "$profile" \
                --region "us-east-1" \
                --time-period Start="$thirty_days_ago",End="$today" \
                --granularity "MONTHLY" \
                --metrics "UnblendedCost" "UsageQuantity" \
                --filter '{"Dimensions": {"Key": "SERVICE", "Values": ["Amazon Elastic Compute Cloud - Compute", "Amazon Bedrock"]}}' \
                --group-by '[{"Type": "DIMENSION", "Key": "SERVICE"}]' \
                --output json 2>/dev/null || echo "{}")

            # Parse out cost / usage results
            parse_ce_values() {
                local json_data="$1"
                local service="$2"
                local metric="$3" # Amount (UnblendedCost) or Usage (UsageQuantity)
                if [ "$metric" = "Amount" ]; then
                    echo "$json_data" | jq -r --arg svc "$service" '
                        .ResultsByTime[].Groups[] | select(.Keys[0] == $svc) | .Metrics.UnblendedCost.Amount
                    ' 2>/dev/null | awk '{s+=$1} END {print s}' | xargs || echo "0.00"
                else
                    echo "$json_data" | jq -r --arg svc "$service" '
                        .ResultsByTime[].Groups[] | select(.Keys[0] == $svc) | .Metrics.UsageQuantity.Amount
                    ' 2>/dev/null | awk '{s+=$1} END {print s}' | xargs || echo "0.00"
                fi
            }

            ce_day_ec2=$(parse_ce_values "$day_res" "Amazon Elastic Compute Cloud - Compute" "Amount")
            ce_day_bedrock=$(parse_ce_values "$day_res" "Amazon Bedrock" "Amount")
            ce_day_bedrock_tok=$(parse_ce_values "$day_res" "Amazon Bedrock" "Usage")

            ce_week_ec2=$(parse_ce_values "$week_res" "Amazon Elastic Compute Cloud - Compute" "Amount")
            ce_week_bedrock=$(parse_ce_values "$week_res" "Amazon Bedrock" "Amount")
            ce_week_bedrock_tok=$(parse_ce_values "$week_res" "Amazon Bedrock" "Usage")

            ce_month_ec2=$(parse_ce_values "$month_res" "Amazon Elastic Compute Cloud - Compute" "Amount")
            ce_month_bedrock=$(parse_ce_values "$month_res" "Amazon Bedrock" "Amount")
            ce_month_bedrock_tok=$(parse_ce_values "$month_res" "Amazon Bedrock" "Usage")
        else
            echo -e "${C_SUBCOMMAND}Warning: AWS Cost Explorer is not enabled or accessible. Using local statistics only.${C_RESET}" >&2
            ce_enabled=false
        fi
    else
        ce_enabled=false
    fi

    # Query AWS Free Tier usage if available
    local freetier_json="[]"
    if command -v aws &>/dev/null; then
        freetier_json=$(aws freetier get-free-tier-usage \
            --profile "$profile" \
            --region "us-east-1" \
            --query "freeTierUsages" \
            --output json 2>/dev/null || echo "[]")
    fi

    # Render results with Python ASCII Grid table helper
    python3 - "$timeframe" \
            "$hour_ec2_hours" "$hour_ec2_cost" "$hour_bedrock_tokens" "$hour_bedrock_cost" \
            "$ce_day_ec2" "$ce_day_bedrock" "$ce_day_bedrock_tok" \
            "$ce_week_ec2" "$ce_week_bedrock" "$ce_week_bedrock_tok" \
            "$ce_month_ec2" "$ce_month_bedrock" "$ce_month_bedrock_tok" \
            "$freetier_json" << 'EOF'
import sys
import json

C_HEADING = "\033[1;38;2;107;80;255m"
C_PRIMARY = "\033[38;2;114;114;255m"
C_SUBCOMMAND = "\033[38;2;255;121;208m"
C_TEXT = "\033[38;2;236;235;240m"
C_FLAG = "\033[38;2;18;199;143m"
C_MUTED = "\033[38;2;116;114;130m"
C_RESET = "\033[0m"

tf_filter = sys.argv[1].strip().lower()

# Parse floats and ints safely
def safe_float(v):
    try: return float(v) if v and v != "None" else 0.0
    except: return 0.0

def safe_int(v):
    try: return int(float(v)) if v and v != "None" else 0
    except: return 0

# Last Hour
h_hours = safe_float(sys.argv[2])
h_ec2_cost = safe_float(sys.argv[3])
h_tok = safe_int(sys.argv[4])
h_bed_cost = safe_float(sys.argv[5])

# Last Day (AWS CE)
d_ec2_cost = safe_float(sys.argv[6])
d_bed_cost = safe_float(sys.argv[7])
d_tok = safe_int(sys.argv[8])

# Last Week
w_ec2_cost = safe_float(sys.argv[9])
w_bed_cost = safe_float(sys.argv[10])
w_tok = safe_int(sys.argv[11])

# Last Month
m_ec2_cost = safe_float(sys.argv[12])
m_bed_cost = safe_float(sys.argv[13])
m_tok = safe_int(sys.argv[14])

try:
    freetier_data = json.loads(sys.argv[15])
except Exception:
    freetier_data = []

rows = [
    ("Last Hour", f"{h_hours:.1f} hrs", f"${h_ec2_cost:.2f}", f"{h_tok:,}", f"${h_bed_cost:.2f}"),
    ("Last Day", "N/A", f"${d_ec2_cost:.2f}", f"{d_tok:,}", f"${d_bed_cost:.2f}"),
    ("Last Week", "N/A", f"${w_ec2_cost:.2f}", f"{w_tok:,}", f"${w_bed_cost:.2f}"),
    ("Last Month", "N/A", f"${m_ec2_cost:.2f}", f"{m_tok:,}", f"${m_bed_cost:.2f}")
]

# Filtering support if --timeframe flag is specified
if tf_filter:
    rows = [r for r in rows if tf_filter in r[0].lower()]

print(f"{C_HEADING}{'Timeframe':<15} | {'EC2 Hours':<12} | {'EC2 Cost':<10} | {'Bedrock Tokens':<15} | {'Bedrock Cost':<12}{C_RESET}")
print(f"{C_MUTED}" + "-" * 75 + f"{C_RESET}")

for r in rows:
    tf, hrs, ec2_c, tok, bed_c = r
    print(f"{C_SUBCOMMAND}{tf:<15}{C_RESET} | {C_TEXT}{hrs:<12}{C_RESET} | {C_TEXT}{ec2_c:<10}{C_RESET} | {C_FLAG}{tok:<15}{C_RESET} | {C_FLAG}{bed_c:<12}{C_RESET}")

# 3. Format Free Tier Status table below if data exists
# Parse out ec2 or bedrock free-tier usages
ft_rows = []
if isinstance(freetier_data, list):
    for u in freetier_data:
        srv = u.get("service", "")
        # Filter for EC2 compute, Bedrock, or any active resources being tracked in Free Tier
        if "Compute" in srv or "Bedrock" in srv or "CloudWatch" in srv or "Dynamo" in srv:
            actual = safe_float(u.get("actualUsageAmount", 0.0))
            limit = safe_float(u.get("limit", 0.0))
            rem = max(0.0, limit - actual)
            unit = u.get("unit", "")
            ft_rows.append((srv, f"{limit:,.2f} {unit}", f"{actual:,.2f} {unit}", f"{rem:,.2f} {unit}"))

if ft_rows:
    print("")
    print(f"{C_HEADING}Free Tier Status (Monthly):{C_RESET}")
    print(f"{C_HEADING}{'Service Name':<42} | {'Limit':<18} | {'Actual Usage':<18} | {'Remaining':<18}{C_RESET}")
    print(f"{C_MUTED}" + "-" * 105 + f"{C_RESET}")
    for srv, lim, act, rem in ft_rows:
        print(f"{C_SUBCOMMAND}{srv:<42}{C_RESET} | {C_TEXT}{lim:<18}{C_RESET} | {C_TEXT}{act:<18}{C_RESET} | {C_FLAG}{rem:<18}{C_RESET}")
else:
    # Print empty notice inside styled layout if no active metrics are found
    print("")
    print(f"{C_HEADING}Free Tier Status (Monthly):{C_RESET}")
    print(f"{C_MUTED}No active Free Tier limits consumed this month for EC2 or Bedrock.{C_RESET}")

EOF
}
