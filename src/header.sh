#!/usr/bin/env bash
# aictf - Agentic Attack Box Manager
set -euo pipefail

# Global Configuration & Paths
AICTF_DIR="${HOME}/.aictf"
CONFIG_FILE="${AICTF_DIR}/config"
SSH_KEYS_DIR="${AICTF_DIR}/ssh-keys"
LLM_KEYS_DIR="${AICTF_DIR}/llm-keys"
RESOURCES_FILE="${AICTF_DIR}/resources"

# Ensure directories exist
mkdir -p "$AICTF_DIR" "$SSH_KEYS_DIR" "$LLM_KEYS_DIR"

# Color Codes
C_HEADING="\033[1;38;2;107;80;255m"     # Bold rgb(107, 80, 255) - USAGE, COMMANDS, FLAGS
C_PRIMARY="\033[38;2;114;114;255m"       # rgb(114, 114, 255) - Commands (crush, dirs, login, completion)
C_SUBCOMMAND="\033[38;2;255;121;208m"    # rgb(255, 121, 208) - Subcommands / Secondary commands
C_TEXT="\033[38;2;236;235;240m"          # rgb(236, 235, 240) - Normal description text
C_FLAG="\033[38;2;18;199;143m"           # rgb(18, 199; 143) - Flags (-c, -d, --cwd, --yolo)
C_MUTED="\033[38;2;116;114;130m"         # rgb(116, 114, 130) - Muted comment hints
C_RESET="\033[0m"
