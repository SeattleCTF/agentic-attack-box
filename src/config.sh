# Config Command Subroutines

cmd_config() {
    local sub="${1:-}"
    if [ -z "$sub" ]; then
        echo -e "${C_HEADING}USAGE${C_RESET}"
        echo -e "  ${C_PRIMARY}aictf config${C_RESET} ${C_SUBCOMMAND}[subcommand]${C_RESET}"
        echo ""
        echo -e "${C_HEADING}SUBCOMMANDS${C_RESET}"
        printf "  ${C_SUBCOMMAND}%-18s${C_RESET} ${C_TEXT}%s${C_RESET}\n" "aws-config" "Configure AWS region and other AWS settings"
        printf "  ${C_SUBCOMMAND}%-18s${C_RESET} ${C_TEXT}%s${C_RESET}\n" "aws-profile" "Set default AWS profile used by aictf"
        printf "  ${C_MUTED}%-18s${C_RESET} ${C_MUTED}%s${C_RESET}\n" "gcloud-config" "Stub (Not implemented yet)"
        printf "  ${C_MUTED}%-18s${C_RESET} ${C_MUTED}%s${C_RESET}\n" "gcloud-profile" "Stub (Not implemented yet)"
        printf "  ${C_MUTED}%-18s${C_RESET} ${C_MUTED}%s${C_RESET}\n" "oci-config" "Stub (Not implemented yet)"
        printf "  ${C_MUTED}%-18s${C_RESET} ${C_MUTED}%s${C_RESET}\n" "oci-profile" "Stub (Not implemented yet)"
        return 0
    fi
    
    case "$sub" in
        aws-config)
            local current_region=$(get_config_value "AWS_REGION" "us-east-1")
            echo -e -n "${C_TEXT}Enter AWS Region [${C_FLAG}${current_region}${C_TEXT}]: ${C_RESET}"
            local region
            read -r region
            region="${region:-$current_region}"
            set_config_value "AWS_REGION" "$region"
            echo -e "${C_FLAG}Success:${C_RESET} ${C_TEXT}AWS region updated to:${C_RESET} ${C_SUBCOMMAND}${region}${C_RESET}"
            ;;
        aws-profile)
            local current_profile=$(get_config_value "AWS_PROFILE" "default")
            echo -e -n "${C_TEXT}Enter AWS Profile [${C_FLAG}${current_profile}${C_TEXT}]: ${C_RESET}"
            local profile
            read -r profile
            profile="${profile:-$current_profile}"
            set_config_value "AWS_PROFILE" "$profile"
            echo -e "${C_FLAG}Success:${C_RESET} ${C_TEXT}AWS profile updated to:${C_RESET} ${C_SUBCOMMAND}${profile}${C_RESET}"
            ;;
        gcloud-config|gcloud-profile|oci-config|oci-profile)
            echo -e "${C_MUTED}Not implemented yet${C_RESET}"
            ;;
        *)
            echo -e "${C_SUBCOMMAND}Unknown config subcommand: ${sub}${C_RESET}" >&2
            exit 1
            ;;
    esac
}
