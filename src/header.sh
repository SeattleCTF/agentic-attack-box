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
