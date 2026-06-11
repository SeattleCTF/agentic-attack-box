# List Command Subroutines

cmd_list() {
    if ! command -v aws &> /dev/null; then
        echo "Error: aws CLI is not installed. Please install it and try again." >&2
        exit 1
    fi
    
    local profile=$(get_config_value "AWS_PROFILE" "default")
    local region=$(get_config_value "AWS_REGION" "us-east-1")
    
    local my_ip=""
    if ! my_ip=$(get_my_ip); then
        my_ip="UNKNOWN"
    fi
    
    local instances_json
    instances_json=$(aws ec2 describe-instances \
        --profile "$profile" \
        --region "$region" \
        --filters "Name=tag:CreatedBy,Values=aictf" "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[*].Instances[*].{InstanceId:InstanceId,State:State.Name,PublicIpAddress:PublicIpAddress,SecurityGroups:SecurityGroups}' \
        --output json 2>/dev/null || echo "[]")
        
    if command -v python3 &> /dev/null; then
        python3 - "$instances_json" "$my_ip" "$profile" "$region" << 'EOF'
import sys
import json
import subprocess

# Define ANSI escape color constants in python matching terminal_output.html scheme
C_HEADING = "\033[1;38;2;107;80;255m"
C_PRIMARY = "\033[38;2;114;114;255m"
C_SUBCOMMAND = "\033[38;2;255;121;208m"
C_TEXT = "\033[38;2;236;235;240m"
C_FLAG = "\033[38;2;18;199;143m"
C_MUTED = "\033[38;2;116;114;130m"
C_RESET = "\033[0m"

try:
    data = json.loads(sys.argv[1])
    my_ip = sys.argv[2]
    profile = sys.argv[3]
    region = sys.argv[4]
except Exception:
    data = []
    my_ip = "UNKNOWN"
    profile = "default"
    region = "us-east-1"

instances = []
if data:
    for reservation in data:
        for inst in reservation:
            instances.append(inst)

# Header matching specifications
headers = f"{C_HEADING}{'Provider':<10} | {'Instance ID':<20} | {'Public IP':<15} | {'Accessible':<10} | {'State':<6}{C_RESET}"
print(headers)
print(f"{C_MUTED}" + "-" * 75 + f"{C_RESET}")

for inst in instances:
    provider = "aws"
    inst_id = inst.get('InstanceId', 'N/A')
    state_raw = inst.get("State", {}).get("Name", "unknown") if isinstance(inst.get("State"), dict) else inst.get("State", "unknown")
    public_ip = inst.get("PublicIpAddress", "N/A")
    if not public_ip:
        public_ip = "N/A"
        
    accessible = "⛔"
    sgs = inst.get("SecurityGroups", [])
    if sgs and my_ip != "UNKNOWN" and public_ip != "N/A":
        for sg in sgs:
            sg_id = sg.get("GroupId")
            if not sg_id:
                continue
            try:
                cmd = [
                    "aws", "ec2", "describe-security-groups",
                    "--profile", profile,
                    "--region", region,
                    "--group-ids", sg_id,
                    "--query", "SecurityGroups[0].IpPermissions[?ToPort==`22`].IpRanges[].CidrIp",
                    "--output", "json"
                ]
                res = subprocess.run(cmd, capture_output=True, text=True)
                if res.returncode == 0 and res.stdout.strip():
                    cidrs = json.loads(res.stdout)
                    if f"{my_ip}/32" in cidrs or "0.0.0.0/0" in cidrs:
                        accessible = "✅"
                        break
            except Exception:
                pass
                
    if state_raw == "running":
        state_icon = "✅"
    elif state_raw == "stopped":
        state_icon = "😴"
    else:
        state_icon = "⏳"
        
    # We apply the colors cleanly with proper formatting string widths so the grid lines remain aligned!
    # \033[38;2;...m sequences are 19 characters of invisible terminal instructions. 
    # By styling the values AFTER setting formatting widths (or using precise print formats), we keep the ASCII column perfectly straight!
    prov_styled = f"{C_FLAG}{provider:<10}{C_RESET}"
    id_styled = f"{C_SUBCOMMAND}{inst_id:<20}{C_RESET}"
    ip_styled = f"{C_TEXT}{public_ip:<15}{C_RESET}"
    acc_styled = f"{accessible:<10}"
    state_styled = f"{state_icon:<6}"
    
    print(f"{prov_styled} | {id_styled} | {ip_styled} | {acc_styled} | {state_styled}")

EOF
    else
        echo -e "${C_HEADING}Provider   | Instance ID          | Public IP       | Accessible | State${C_RESET}"
        echo -e "${C_MUTED}------------------------------------------------------------------------${C_RESET}"
        if command -v jq &> /dev/null; then
            local len=$(echo "$instances_json" | jq '. | flatten | length')
            for ((i=0; i<len; i++)); do
                local inst_id=$(echo "$instances_json" | jq -r ". | flatten | .[$i].InstanceId")
                local state_raw=$(echo "$instances_json" | jq -r ". | flatten | .[$i].State")
                local public_ip=$(echo "$instances_json" | jq -r ". | flatten | .[$i].PublicIpAddress")
                if [ "$public_ip" = "null" ] || [ -z "$public_ip" ]; then
                    public_ip="N/A"
                fi
                
                local accessible="⛔"
                if [ "$public_ip" != "N/A" ] && [ "$my_ip" != "UNKNOWN" ]; then
                    local sgs=$(echo "$instances_json" | jq -r ". | flatten | .[$i].SecurityGroups[].GroupId")
                    for sg_id in $sgs; do
                        local cidrs=$(aws ec2 describe-security-groups --profile "$profile" --region "$region" --group-ids "$sg_id" --query "SecurityGroups[0].IpPermissions[?ToPort==\`22\`].IpRanges[].CidrIp" --output text 2>/dev/null || true)
                        if echo "$cidrs" | grep -q -E "(${my_ip}/32|0\.0\.0\.0/0)"; then
                            accessible="✅"
                            break
                        fi
                    done
                fi
                
                local state_icon="⏳"
                if [ "$state_raw" = "running" ]; then
                    state_icon="✅"
                elif [ "$state_raw" = "stopped" ]; then
                    state_icon="😴"
                fi
                
                # Align columns cleanly before applying style markers
                printf "${C_FLAG}%-10s${C_RESET} | ${C_SUBCOMMAND}%-20s${C_RESET} | ${C_TEXT}%-15s${C_RESET} | %-10s | %-6s\n" "aws" "$inst_id" "$public_ip" "$accessible" "$state_icon"
            done
        else
            echo "No python3 or jq available to render the list table." >&2
            echo "Raw JSON data:" >&2
            echo "$instances_json" >&2
        fi
    fi
}
