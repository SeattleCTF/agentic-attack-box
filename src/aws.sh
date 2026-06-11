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
        echo "Instance is not accessible from your current IP ($my_ip)." >&2
        echo "Automatically running 'aictf aws access' to whitelist your IP..." >&2
        cmd_aws_access "$instance_id"
    fi
    
    local key_file="${SSH_KEYS_DIR}/aictf_key"
    echo "Connecting to ${ssh_user}@${public_ip}..."
    ssh -i "$key_file" -o StrictHostKeyChecking=no "${ssh_user}@${public_ip}"
}

cmd_aws_start() {
    local instance_id=$(select_aws_instance "${1:-}")
    local profile=$(get_config_value "AWS_PROFILE" "default")
    local region=$(get_config_value "AWS_REGION" "us-east-1")
    
    echo "Starting instance $instance_id..."
    aws ec2 start-instances --profile "$profile" --region "$region" --instance-ids "$instance_id" >/dev/null
    echo "Instance start request submitted. It may take a minute to boot."
}

cmd_aws_stop() {
    local instance_id=$(select_aws_instance "${1:-}")
    local profile=$(get_config_value "AWS_PROFILE" "default")
    local region=$(get_config_value "AWS_REGION" "us-east-1")
    
    echo "Stopping instance $instance_id..."
    aws ec2 stop-instances --profile "$profile" --region "$region" --instance-ids "$instance_id" >/dev/null
    echo "Instance stop request submitted."
}

cmd_aws_destroy() {
    local instance_id=$(select_aws_instance "${1:-}")
    local profile=$(get_config_value "AWS_PROFILE" "default")
    local region=$(get_config_value "AWS_REGION" "us-east-1")
    
    echo -n "Are you sure you want to destroy instance ${instance_id}? [y/N]: "
    local confirmation
    read -r confirmation
    if [[ ! "$confirmation" =~ ^[Yy]$ ]]; then
        echo "Termination aborted."
        return 0
    fi
    
    echo "Terminating instance $instance_id..."
    aws ec2 terminate-instances --profile "$profile" --region "$region" --instance-ids "$instance_id" >/dev/null
    deregister_resource "instance" "$instance_id" "aws" "$region"
    echo "Instance termination request submitted."
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
        echo "Error: Could not find security group for instance $instance_id." >&2
        exit 1
    fi
    
    echo "Updating Security Group $sg_id to authorize port 22 ingress for $my_ip/32..."
    
    local existing_rules=$(aws ec2 describe-security-groups \
        --profile "$profile" \
        --region "$region" \
        --group-ids "$sg_id" \
        --query "SecurityGroups[0].IpPermissions[?ToPort==\`22\`].IpRanges[].CidrIp" \
        --output text)
        
    for cidr in $existing_rules; do
        if [ -n "$cidr" ] && [ "$cidr" != "None" ]; then
            echo "Revoking existing ingress rule for $cidr..."
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
        echo "Error: No valid LLM credentials found to sync." >&2
        exit 1
    fi
    
    # 2. Get active instances
    local instances_raw=$(get_active_instances)
    if [ -z "$instances_raw" ]; then
        echo "No active AWS instances found to sync."
        return 0
    fi
    
    local lines=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            lines+=("$line")
        fi
    done <<< "$instances_raw"
    
    echo "Found ${#lines[@]} instance(s) in region $region. Syncing credentials via SSH..."
    
    for line in "${lines[@]}"; do
        local inst_id=$(echo "$line" | awk '{print $1}')
        local state=$(echo "$line" | awk '{print $2}')
        local public_ip=$(echo "$line" | awk '{print $3}')
        
        if [ "$state" != "running" ]; then
            echo "Skipping instance $inst_id because it is in state: $state"
            continue
        fi
        
        if [ "$public_ip" = "None" ] || [ -z "$public_ip" ] || [ "$public_ip" = "null" ]; then
            echo "Skipping instance $inst_id because it does not have a public IP address."
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
        
        echo "Syncing credentials to $inst_id ($public_ip) as user '$ssh_user'..."
        
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
            echo "Access not open. Auto-whitelisting your IP in security group..." >&2
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
    echo "Credential sync complete."
}

cmd_aws_sync_skills() {
    local profile=$(get_config_value "AWS_PROFILE" "default")
    local region=$(get_config_value "AWS_REGION" "us-east-1")
    
    local instances_raw=$(get_active_instances)
    if [ -z "$instances_raw" ]; then
        echo "No active AWS instances found to sync skills."
        return 0
    fi
    
    local lines=()
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            lines+=("$line")
        fi
    done <<< "$instances_raw"
    
    echo "Found ${#lines[@]} instance(s) in region $region. Syncing agent skills via SSH..."
    
    for line in "${lines[@]}"; do
        local inst_id=$(echo "$line" | awk '{print $1}')
        local state=$(echo "$line" | awk '{print $2}')
        local public_ip=$(echo "$line" | awk '{print $3}')
        
        if [ "$state" != "running" ]; then
            echo "Skipping instance $inst_id because it is in state: $state"
            continue
        fi
        
        if [ "$public_ip" = "None" ] || [ -z "$public_ip" ] || [ "$public_ip" = "null" ]; then
            echo "Skipping instance $inst_id because it does not have a public IP address."
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
        
        echo "Syncing skills to $inst_id ($public_ip) as user '$ssh_user'..."
        
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
            echo "Access not open. Auto-whitelisting your IP in security group..." >&2
            cmd_aws_access "$inst_id"
        fi
        
        # Sync all local skills from skills/ directory on host using inline transfer
        # This allows users to easily add/edit skills locally and sync them via sync-skills
        if [ -d "/home/remix/SeattleCTF/agentic-attack-box/skills" ]; then
            for skill_path in /home/remix/SeattleCTF/agentic-attack-box/skills/*; do
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
    echo "Skill sync complete."
}
