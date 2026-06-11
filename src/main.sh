# Global CLI Entrypoint & Argument Parsing

show_help() {
    echo "aictf - Agentic Attack Box Manager"
    echo ""
    echo "Usage: aictf <command> [subcommand] [arguments]"
    echo ""
    echo "Global Commands:"
    echo "  list                     List all tracked attack boxes and states"
    echo "  config [subcommand]      Manage configurations (~/.aictf/config)"
    echo "  help | -h | --help       Show this help menu"
    echo ""
    echo "AWS Commands (aictf aws [subcommand]):"
    echo "  aws                      Show current AWS configuration and status"
    echo "  aws create               Provision a new cloud-based attack box"
    echo "  aws shell [id]           Connect to an instance via SSH"
    echo "  aws start [id]           Start a stopped instance"
    echo "  aws stop [id]            Stop a running instance"
    echo "  aws destroy [id]         Terminate an instance permanently"
    echo "  aws access [id]          Authorize current IP for SSH"
    echo "  aws sync-creds           Sync LLM (Gemini/Bedrock) credentials to active instances"
    echo ""
    echo "Planned Providers:"
    echo "  gcloud                   Google Cloud Platform (Not implemented yet)"
    echo "  oci                      Oracle Cloud Infrastructure (Not implemented yet)"
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
                echo "AWS Configuration & CLI Status:"
                local profile=$(get_config_value "AWS_PROFILE" "default")
                local region=$(get_config_value "AWS_REGION" "us-east-1")
                echo "  Profile: $profile"
                echo "  Region:  $region"
                echo ""
                if check_aws_auth; then
                    echo "Status: Authenticated ✅"
                else
                    echo "Status: Not Authenticated ❌"
                    echo "Please configure your AWS CLI or run:"
                    echo "  aictf config aws-profile"
                    echo "  aictf config aws-config"
                fi
                echo ""
                echo "Available Subcommands:"
                echo "  create, shell, start, stop, destroy, access"
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
                        echo "Locating latest Kali Linux AMI..." >&2
                        ami_id=$(aws ec2 describe-images \
                            --profile "$profile" \
                            --region "$region" \
                            --owners 679593333241 \
                            --filters "Name=name,Values=kali-last-release-amd64-*" "Name=state,Values=available" \
                            --query "sort_by(Images, &CreationDate)[-1].ImageId" \
                            --output text 2>/dev/null || true)
                        if [ -z "$ami_id" ] || [ "$ami_id" = "None" ] || [ "$ami_id" = "null" ]; then
                            echo "Could not locate Kali Linux AMI in region $region. Falling back to Debian 12." >&2
                            os_choice="Debian"
                        fi
                    fi
                    
                    if [ -z "$ami_id" ] || [ "$ami_id" = "None" ] || [ "$ami_id" = "null" ]; then
                        echo "Locating latest Debian 12 AMI..." >&2
                        ami_id=$(aws ec2 describe-images \
                            --profile "$profile" \
                            --region "$region" \
                            --owners 136693071363 \
                            --filters "Name=name,Values=debian-12-amd64-*" "Name=state,Values=available" "Name=architecture,Values=x86_64" "Name=virtualization-type,Values=hvm" \
                            --query "sort_by(Images, &CreationDate)[-1].ImageId" \
                            --output text 2>/dev/null || true)
                    fi
                    
                    if [ -z "$ami_id" ] || [ "$ami_id" = "None" ] || [ "$ami_id" = "null" ]; then
                        echo "Using default Debian 12 AMI fallback..." >&2
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
                            echo "Warning: Debian AMI not found, falling back to Amazon Linux: $ami_id" >&2
                        fi
                    fi
                    
                    local sg_id=""
                    echo "Checking for existing aictf security group..." >&2
                    sg_id=$(aws ec2 describe-security-groups \
                        --profile "$profile" \
                        --region "$region" \
                        --filters "Name=group-name,Values=aictf-security-group" "Name=vpc-id,Values=$vpc_id" \
                        --query "SecurityGroups[0].GroupId" \
                        --output text 2>/dev/null || true)
                        
                    if [ -z "$sg_id" ] || [ "$sg_id" = "None" ] || [ "$sg_id" = "null" ]; then
                        echo "Creating security group aictf-security-group..." >&2
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
                    echo "Whitelisting port 22 for your current IP: $my_ip" >&2
                    aws ec2 authorize-security-group-ingress \
                        --profile "$profile" \
                        --region "$region" \
                        --group-id "$sg_id" \
                        --protocol tcp \
                        --port 22 \
                        --cidr "${my_ip}/32" &>/dev/null || true
                        
                    local key_name="aictf-keypair"
                    if ! aws ec2 describe-key-pairs --profile "$profile" --region "$region" --key-names "$key_name" &>/dev/null; then
                        echo "Importing public key to AWS EC2..." >&2
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
                    
                    cat <<EOF > "$user_data_file"
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
mkdir -p "\${USER_HOME}/.ssh"
echo "$(cat ${SSH_KEYS_DIR}/aictf_key.pub)" >> "\${USER_HOME}/.ssh/authorized_keys"
chown -R ${target_user}:${target_user} "\${USER_HOME}/.ssh"
chmod 700 "\${USER_HOME}/.ssh"
chmod 600 "\${USER_HOME}/.ssh/authorized_keys"
echo "$llm_env_setup" >> "\${USER_HOME}/.bashrc"
echo "$llm_env_setup" >> "/home/${target_user}/.profile"
chown ${target_user}:${target_user} "\${USER_HOME}/.bashrc" "\${USER_HOME}/.profile"
while read -r line; do
    if [ -n "\$line" ]; then
        echo "\$line" >> /etc/environment
    fi
done << 'ENV_EOF'
$llm_env_setup
ENV_EOF
echo "=== AICFT BOOTSTRAP COMPLETE ==="
EOF
                    local inst_type="t2.micro"
                    echo "Launching EC2 instance ($inst_type)..." >&2
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
                    echo "Successfully launched instance: $instance_id"
                    echo "You can check status with: aictf list"
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
