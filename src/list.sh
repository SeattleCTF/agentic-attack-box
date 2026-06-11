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
print(f"{'Provider':<10} | {'Instance ID':<20} | {'Public IP':<15} | {'Accessible':<10} | {'State':<6}")
print("-" * 75)

for inst in instances:
    provider = "aws"
    inst_id = inst.get("InstanceId", "N/A")
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
        
    print(f"{provider:<10} | {inst_id:<20} | {public_ip:<15} | {accessible:<10} | {state_icon:<6}")

EOF
    else
        echo "Provider   | Instance ID          | Public IP       | Accessible | State"
        echo "------------------------------------------------------------------------"
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
                
                printf "%-10s | %-20s | %-15s | %-10s | %-6s\n" "aws" "$inst_id" "$public_ip" "$accessible" "$state_icon"
            done
        else
            echo "No python3 or jq available to render the list table." >&2
            echo "Raw JSON data:" >&2
            echo "$instances_json" >&2
        fi
    fi
}
