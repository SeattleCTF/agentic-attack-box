# Config Command Subroutines

cmd_config() {
    local sub="${1:-}"
    if [ -z "$sub" ]; then
        echo "Usage: aictf config [subcommand]"
        echo ""
        echo "Subcommands:"
        echo "  aws-config         Configure AWS region and other AWS settings"
        echo "  aws-profile        Set default AWS profile used by aictf"
        echo "  gcloud-config      Stub (Not implemented yet)"
        echo "  gcloud-profile     Stub (Not implemented yet)"
        echo "  oci-config         Stub (Not implemented yet)"
        echo "  oci-profile        Stub (Not implemented yet)"
        return 0
    fi
    
    case "$sub" in
        aws-config)
            local current_region=$(get_config_value "AWS_REGION" "us-east-1")
            echo -n "Enter AWS Region [$current_region]: "
            local region
            read -r region
            region="${region:-$current_region}"
            set_config_value "AWS_REGION" "$region"
            echo "AWS region updated to: $region"
            ;;
        aws-profile)
            local current_profile=$(get_config_value "AWS_PROFILE" "default")
            echo -n "Enter AWS Profile [$current_profile]: "
            local profile
            read -r profile
            profile="${profile:-$current_profile}"
            set_config_value "AWS_PROFILE" "$profile"
            echo "AWS profile updated to: $profile"
            ;;
        gcloud-config|gcloud-profile|oci-config|oci-profile)
            echo "Not implemented yet"
            ;;
        *)
            echo "Unknown config subcommand: $sub" >&2
            exit 1
            ;;
    esac
}
