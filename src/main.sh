# Global CLI Entrypoint & Argument Parsing

show_help() {
    echo -e "${C_TEXT}aictf - agentic attack box orchestrator${C_RESET}"
    echo ""
    echo -e "${C_HEADING}USAGE${C_RESET}"
    echo -e "  ${C_PRIMARY}aictf${C_RESET} ${C_SUBCOMMAND}[command]${C_RESET} ${C_MUTED}[subcommand] [--flags]${C_RESET}"
    echo ""
    echo -e "${C_HEADING}GLOBAL COMMANDS${C_RESET}"
    printf "  ${C_SUBCOMMAND}%-24s${C_RESET} ${C_TEXT}%s${C_RESET}\n" "list" "List all tracked attack boxes and states"
    printf "  ${C_SUBCOMMAND}%-24s${C_RESET} ${C_TEXT}%s${C_RESET}\n" "config [subcmd]" "Manage configurations (~/.aictf/config)"
    printf "  ${C_SUBCOMMAND}%-24s${C_RESET} ${C_TEXT}%s${C_RESET}\n" "help" "Show this help menu"
    echo ""
    echo -e "${C_HEADING}AWS COMMANDS${C_RESET}"
    printf "  ${C_FLAG}%-24s${C_RESET} ${C_TEXT}%s${C_RESET}\n" "aws" "Show current AWS configuration and status"
    printf "  ${C_FLAG}%-24s${C_RESET} ${C_TEXT}%s${C_RESET}\n" "aws create" "Provision a new cloud-based attack box"
    printf "  ${C_FLAG}%-24s${C_RESET} ${C_TEXT}%s${C_RESET}\n" "aws shell [id]" "Connect to an instance via SSH"
    printf "  ${C_FLAG}%-24s${C_RESET} ${C_TEXT}%s${C_RESET}\n" "aws start [id]" "Start a stopped instance"
    printf "  ${C_FLAG}%-24s${C_RESET} ${C_TEXT}%s${C_RESET}\n" "aws stop [id]" "Stop a running instance"
    printf "  ${C_FLAG}%-24s${C_RESET} ${C_TEXT}%s${C_RESET}\n" "aws destroy [id]" "Terminate an instance permanently"
    printf "  ${C_FLAG}%-24s${C_RESET} ${C_RESET} ${C_TEXT}%s${C_RESET}\n" "aws access [id]" "Authorize current IP for SSH"
    printf "  ${C_FLAG}%-24s${C_RESET} ${C_TEXT}%s${C_RESET}\n" "aws sync-creds" "Sync LLM (Gemini/Bedrock) credentials to active instances"
    printf "  ${C_FLAG}%-24s${C_RESET} ${C_TEXT}%s${C_RESET}\n" "aws sync-skills" "Sync Crush agent skills (like htb-web) to active instances"
    printf "  ${C_FLAG}%-24s${C_RESET} ${C_TEXT}%s${C_RESET}\n" "aws usage" "View resource consumption and cost aggregated summaries"
    echo ""
    echo -e "${C_HEADING}PLANNED PROVIDERS${C_RESET}"
    printf "  ${C_MUTED}%-24s${C_RESET} ${C_MUTED}%s${C_RESET}\n" "gcloud" "Google Cloud Platform (Not implemented yet)"
    printf "  ${C_MUTED}%-24s${C_RESET} ${C_MUTED}%s${C_RESET}\n" "oci" "Oracle Cloud Infrastructure (Not implemented yet)"
    echo ""
}

main() {
    if [ $# -lt 1 ]; then
        show_help
        exit 0
    fi
    
    local cmd="$1"
    shift
    
    case "$cmd" in
        help|-h|--help)
            show_help
            ;;
        list)
            cmd_list
            ;;
        config)
            cmd_config "${1:-}"
            ;;
        aws)
            local sub="${1:-}"
            if [ -z "$sub" ]; then
                echo -e "${C_HEADING}AWS Configuration & CLI Status:${C_RESET}"
                local profile=$(get_config_value "AWS_PROFILE" "default")
                local region=$(get_config_value "AWS_REGION" "us-east-1")
                echo -e "  ${C_TEXT}Profile:${C_RESET} ${C_SUBCOMMAND}${profile}${C_RESET}"
                echo -e "  ${C_TEXT}Region:${C_RESET}  ${C_SUBCOMMAND}${region}${C_RESET}"
                echo ""
                if check_aws_auth; then
                    echo -e "${C_TEXT}Status:${C_RESET} ${C_FLAG}Authenticated ✅${C_RESET}"
                else
                    echo -e "${C_TEXT}Status:${C_RESET} ${C_SUBCOMMAND}Not Authenticated ❌${C_RESET}"
                    echo -e "${C_MUTED}Please configure your AWS CLI or run:${C_RESET}"
                    echo -e "  ${C_PRIMARY}aictf config aws-profile${C_RESET}"
                    echo -e "  ${C_PRIMARY}aictf config aws-config${C_RESET}"
                fi
                echo ""
                echo -e "${C_HEADING}Available Subcommands:${C_RESET}"
                echo -e "  ${C_FLAG}create, shell, start, stop, destroy, access, sync-creds, sync-skills, usage${C_RESET}"
                return 0
            fi
            shift
            
            case "$sub" in
                create)
                    generate_ssh_key
                    setup_llm_token
                    
                    local profile=$(get_config_value "AWS_PROFILE" "default")
                    local region=$(get_config_value "AWS_REGION" "us-east-1")
                    
                    # Ensure correct network environment (creates VPC if no default is found)
                    local net_env
                    net_env=$(ensure_network_env "$profile" "$region")
                    local vpc_id=$(echo "$net_env" | cut -d'|' -f1)
                    local subnet_id=$(echo "$net_env" | cut -d'|' -f2)
                    
                    local os_choice
                    os_choice=$(select_item "Select OS for Attack Box" "Debian 12 (Recommended)" "Kali Linux (Requires marketplace subscription)")
                    
                    local ami_id=""
                    if [[ "$os_choice" == *"Kali"* ]]; then
                        echo -e "${C_FLAG}Locating latest Kali Linux AMI...${C_RESET}" >&2
                        ami_id=$(aws ec2 describe-images \
                            --profile "$profile" \
                            --region "$region" \
                            --owners 679593333241 \
                            --filters "Name=name,Values=kali-last-release-amd64-*" "Name=state,Values=available" \
                            --query "sort_by(Images, &CreationDate)[-1].ImageId" \
                            --output text 2>/dev/null || true)
                        if [ -z "$ami_id" ] || [ "$ami_id" = "None" ] || [ "$ami_id" = "null" ]; then
                            echo -e "${C_SUBCOMMAND}Could not locate Kali Linux AMI in region $region. Falling back to Debian 12.${C_RESET}" >&2
                            os_choice="Debian"
                        fi
                    fi
                    
                    if [ -z "$ami_id" ] || [ "$ami_id" = "None" ] || [ "$ami_id" = "null" ]; then
                        echo -e "${C_FLAG}Locating latest Debian 12 AMI...${C_RESET}" >&2
                        ami_id=$(aws ec2 describe-images \
                            --profile "$profile" \
                            --region "$region" \
                            --owners 136693071363 \
                            --filters "Name=name,Values=debian-12-amd64-*" "Name=state,Values=available" "Name=architecture,Values=x86_64" "Name=virtualization-type,Values=hvm" \
                            --query "sort_by(Images, &CreationDate)[-1].ImageId" \
                            --output text 2>/dev/null || true)
                    fi
                    
                    if [ -z "$ami_id" ] || [ "$ami_id" = "None" ] || [ "$ami_id" = "null" ]; then
                        echo -e "${C_MUTED}Using default Debian 12 AMI fallback...${C_RESET}" >&2
                        if [ "$region" = "us-east-1" ]; then
                            ami_id="ami-058bd2d568351da34"
                        elif [ "$region" = "us-west-2" ]; then
                            ami_id="ami-03c7c1f17004256be"
                        else
                            ami_id=$(aws ec2 describe-images \
                                --profile "$profile" \
                                --region "$region" \
                                --owners amazon \
                                --filters "Name=name,Values=al2023-ami-2023.*-kernel-6.1-x86_64" \
                                --query "sort_by(Images, &CreationDate)[-1].ImageId" \
                                --output text 2>/dev/null || true)
                            echo -e "${C_SUBCOMMAND}Warning: Debian AMI not found, falling back to Amazon Linux: $ami_id${C_RESET}" >&2
                        fi
                    fi
                    
                    local sg_id=""
                    echo -e "${C_MUTED}Checking for existing aictf security group...${C_RESET}" >&2
                    sg_id=$(aws ec2 describe-security-groups \
                        --profile "$profile" \
                        --region "$region" \
                        --filters "Name=group-name,Values=aictf-security-group" "Name=vpc-id,Values=$vpc_id" \
                        --query "SecurityGroups[0].GroupId" \
                        --output text 2>/dev/null || true)
                        
                    if [ -z "$sg_id" ] || [ "$sg_id" = "None" ] || [ "$sg_id" = "null" ]; then
                        echo -e "${C_FLAG}Creating security group aictf-security-group...${C_RESET}" >&2
                        sg_id=$(aws ec2 create-security-group \
                            --profile "$profile" \
                            --region "$region" \
                            --group-name "aictf-security-group" \
                            --description "Security group for aictf agentic attack box" \
                            --vpc-id "$vpc_id" \
                            --query "GroupId" \
                            --output text)
                    fi
                    register_resource "security-group" "$sg_id" "aws" "$region" "Name: aictf-security-group"
                    
                    local my_ip=$(get_my_ip)
                    echo -e "${C_FLAG}Whitelisting port 22 for your current IP: $my_ip${C_RESET}" >&2
                    aws ec2 authorize-security-group-ingress \
                        --profile "$profile" \
                        --region "$region" \
                        --group-id "$sg_id" \
                        --protocol tcp \
                        --port 22 \
                        --cidr "${my_ip}/32" &>/dev/null || true
                        
                    local key_name="aictf-keypair"
                    if ! aws ec2 describe-key-pairs --profile "$profile" --region "$region" --key-names "$key_name" &>/dev/null; then
                        echo -e "${C_FLAG}Importing public key to AWS EC2...${C_RESET}" >&2
                        aws ec2 import-key-pair \
                            --profile "$profile" \
                            --region "$region" \
                            --key-name "$key_name" \
                            --public-key-material "fileb://${SSH_KEYS_DIR}/aictf_key.pub"
                    fi
                    register_resource "key-pair" "$key_name" "aws" "$region" "Imported"
                    
                    local user_data_file=$(mktemp)
                    local target_user="admin"
                    if [[ "$os_choice" == *"Kali"* ]]; then
                        target_user="kali"
                    fi
                    
                    local llm_env_setup=""
                    if [ -f "${LLM_KEYS_DIR}/gemini" ]; then
                        local gemini_val=$(cat "${LLM_KEYS_DIR}/gemini")
                        llm_env_setup="export GEMINI_API_KEY='${gemini_val}'"
                    elif [ -f "${LLM_KEYS_DIR}/bedrock" ]; then
                        llm_env_setup=$(cat "${LLM_KEYS_DIR}/bedrock")
                    fi

                    USER_HOME="/home/${target_user}"
                    
                    cat << EOF > "$user_data_file"
#!/bin/bash
set -x
exec > >(tee -a /var/log/aictf-bootstrap.log) 2>&1
echo "=== AICFT BOOTSTRAP START ==="
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do
    sleep 3
done
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl gnupg openvpn tmux git jq make build-essential
apt-get install -y nmap dnsrecon nikto hydra sqlmap gobuster standard-seclists || true
mkdir -p /etc/apt/keyrings
curl -fsSL https://repo.charm.sh/apt/gpg.key | gpg --dearmor -o /etc/apt/keyrings/charm.gpg
echo "deb [signed-by=/etc/apt/keyrings/charm.gpg] https://repo.charm.sh/apt/ * *" > /etc/apt/sources.list.d/charm.list
apt-get update -y
apt-get install -y gum crush || true
USER_HOME="/home/${target_user}"
mkdir -p "${USER_HOME}/.ssh"
echo "$(cat ${SSH_KEYS_DIR}/aictf_key.pub)" >> "${USER_HOME}/.ssh/authorized_keys"
chown -R ${target_user}:${target_user} "${USER_HOME}/.ssh"
chmod 700 "${USER_HOME}/.ssh"
chmod 600 "${USER_HOME}/.ssh/authorized_keys"

# Create Crush Agent Skill directory and write all local skills
mkdir -p "${USER_HOME}/.agents/skills/"

# Inject all local skills from skills/ directory
# Use a dynamic directory reader if skills exist, otherwise fallback
# Penderrin2004 Edit
if [ -d "$AICTF_CODE_DIR/skills" ]; then
    for skill_path in $AICTF_CODE_DIR/skills/*; do
        if [ -d "\$skill_path" ]; then
            skill_name=$(basename "\$skill_path")
            mkdir -p "${USER_HOME}/.agents/skills/\${skill_name}"
            cat << SKILL_OUTER_EOF > "${USER_HOME}/.agents/skills/\${skill_name}/SKILL.md"
cat "\$skill_path/SKILL.md"
SKILL_OUTER_EOF
        fi
    done
else
    # Fallback default htb-web skill if skills dir is missing
    mkdir -p "${USER_HOME}/.agents/skills/htb-web/"
    cat << 'SKILL_EOF' > "${USER_HOME}/.agents/skills/htb-web/SKILL.md"
EOF
                    cat << 'SKILLED' >> "$user_data_file"
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
SKILL_EOF
SKILLED
                    cat << EOF2 >> "$user_data_file"
fi

chown -R ${target_user}:${target_user} "${USER_HOME}/.agents"

echo "$llm_env_setup" >> "${USER_HOME}/.bashrc"
echo "$llm_env_setup" >> "/home/${target_user}/.profile"
chown ${target_user}:${target_user} "${USER_HOME}/.bashrc" "${USER_HOME}/.profile"
while read -r line; do
    if [ -n "\$line" ]; then
        echo "\$line" >> /etc/environment
    fi
done << 'ENV_EOF'
$llm_env_setup
ENV_EOF
echo "=== AICFT BOOTSTRAP COMPLETE ==="
EOF2
                    # Penderrin2004 Edit
                    local inst_type="t3.small"
                    echo -e "${C_FLAG}Launching EC2 instance ($inst_type)...${C_RESET}" >&2
                    local instance_id
                    instance_id=$(aws ec2 run-instances \
                        --profile "$profile" \
                        --region "$region" \
                        --image-id "$ami_id" \
                        --instance-type "$inst_type" \
                        --key-name "$key_name" \
                        --subnet-id "$subnet_id" \
                        --security-group-ids "$sg_id" \
                        --user-data "file://$user_data_file" \
                        --tag-specifications "ResourceType=instance,Tags=[{Key=CreatedBy,Value=aictf},{Key=Name,Value=aictf-attack-box}]" \
                        --query "Instances[0].InstanceId" \
                        --output text)
                    rm -f "$user_data_file"
                    register_resource "instance" "$instance_id" "aws" "$region" "Type: ${inst_type}"
                    echo -e "${C_FLAG}Success:${C_RESET} ${C_TEXT}Successfully launched instance:${C_RESET} ${C_SUBCOMMAND}$instance_id${C_RESET}"
                    echo -e "${C_MUTED}You can check status with:${C_RESET} ${C_PRIMARY}aictf list${C_RESET}"
                    ;;
                shell)
                    cmd_aws_shell "${1:-}"
                    ;;
                start)
                    cmd_aws_start "${1:-}"
                    ;;
                stop)
                    cmd_aws_stop "${1:-}"
                    ;;
                destroy)
                    cmd_aws_destroy "${1:-}"
                    ;;
                access)
                    cmd_aws_access "${1:-}"
                    ;;
                sync-creds)
                    cmd_aws_sync_creds
                    ;;
                sync-skills)
                    cmd_aws_sync_skills
                    ;;
                usage)
                    cmd_aws_usage "$@"
                    ;;
                *)
                    echo "Unknown AWS subcommand: $sub" >&2
                    exit 1
                    ;;
            esac
            ;;
        gcloud|oci)
            echo "Not implemented yet"
            ;;
        *)
            echo "Unknown command: $cmd" >&2
            show_help
            exit 1
            ;;
    esac
}

# Run main if executed directly
if [ "${BASH_SOURCE[0]}" = "$0" ] || [ "${_AICFT_BUNDLED:-0}" = "1" ] || [ "${_AICFT_BUNDLED:-0}" = "" ]; then
    main "$@"
fi
