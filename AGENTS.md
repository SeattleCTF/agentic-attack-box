# Agent Guide for `aictf` Codebase

Welcome, agent! This guide explains the architecture, compilation patterns, and coding conventions of `aictf` to help you work efficiently in this repository without trial-and-error.

---

## 🏗️ Architecture & Component Design

The project uses a **Modular Bash-to-Single-Binary** architecture. All sources reside in `src/`, and the build step compiles them into a single self-contained executable.

### File Organization
```text
.
├── Makefile                     # Build and install orchestration
├── bin/
│   └── aictf                    # Built standalone executable (gitignore-d)
├── reference/
│   └── start-htb-kali.sh        # Reference script for EC2 Kali status management
└── src/                         # Source components (modules)
    ├── header.sh                # Shebang, bash flags, paths, and env directories
    ├── utils.sh                 # Generic helpers (IP lookup, prompt selectors, keys)
    ├── config.sh                # Config-specific subcommands (aws-config, etc.)
    ├── list.sh                  # Instance table rendering (Python/jq parsers)
    ├── aws.sh                   # AWS actions (create, shell, stop, start, etc.)
    └── main.sh                  # CLI entrypoint, router, and AWS subcommands
```

### Control Flow & Bundling
- During compilation (`make aictf`), the `Makefile` creates `bin/aictf` by prepending a shebang and sequentially concatenating the modules:
  `header.sh` ➡️ `utils.sh` ➡️ `config.sh` ➡️ `list.sh` ➡️ `aws.sh` ➡️ `main.sh`.
- To avoid multiple shebangs, `header.sh` has its first line stripped during concatenation (`tail -n +2`). All other modules inside `src/` **must not** contain any shebang headers (`#!/bin/bash`).

---

## 🛠️ Essential Commands

### Build Standalone Binary
```bash
make aictf
```
Generates the executable inside `bin/aictf`.

### Install to System PATH
```bash
make install
```
Copies the compiled binary to `~/.local/bin/aictf` and marks it executable.

### Clean Build Directory
```bash
make clean
```
Deletes the `bin/` directory.

---

## 📋 Coding Conventions & Style Patterns

1. **State Directories**:
   All state is localized under `~/.aictf/`:
   - `~/.aictf/config` (Global configurations in `KEY=VALUE` format)
   - `~/.aictf/ssh-keys/aictf_key` (Automatically generated ed25519 SSH keys)
   - `~/.aictf/llm-keys/` (`gemini` or `bedrock` credential files for `crush` context injection)
   - `~/.aictf/resources` (Tracked cloud and local resources managed by `aictf` in a pipe-separated schema)

2. **Resource Tracking**:
   All local and cloud resources created/managed by `aictf` (such as local SSH keys, LLM tokens, AWS security groups, EC2 imported key-pairs, and spawned instances) are logged and updated dynamically inside the `~/.aictf/resources` tracking database.
   - Use `register_resource "type" "id" "provider" "region" "metadata"` inside code to document new resources.
   - Use `deregister_resource "type" "id" "provider" "region"` when destroying resources.

3. **LLM Credential Syncing**:
   - Subcommand `aictf aws sync-creds` triggers interactive configuration or dynamic resolution of LLM credentials (Gemini API keys or Bedrock IAM profiles) and automatically SSHs into all running EC2 instances in that region to safely write them to user `.bashrc` profiles and `/etc/environment`.

4. **Error Handling**:
   - Every file is executed under `set -euo pipefail` (defined in `header.sh`).
   - Use `local` variables in all functions to prevent namespace pollution.
   - For commands that can fail but should have fallback behavior, append `|| true` or handle the exit status cleanly.

3. **Helper Convention**:
   - Prefixes for subcommand subroutines should follow the `cmd_<topic>_<action>` or `cmd_<topic>` pattern (e.g. `cmd_aws_shell`, `cmd_config`).
   - Generic shared helper functions are placed in `utils.sh`.

---

## 💡 Important Gotchas & Non-Obvious Behaviors

### 1. The Single Shebang Rule
Do **not** add `#!/usr/bin/env bash` or `#!/bin/bash` to any new module in `src/`. The build pipeline handles shebang creation. Redundant shebangs will appear inline in the bundled file and may cause parsing errors.

### 2. Multi-Tier Table Rendering
In `src/list.sh`, we dynamically format a gorgeous ASCII grid for EC2 instances. The system implements a **multi-tier fallback**:
1. **Tier 1 (Python 3)**: If `python3` is available in `$PATH`, the script passes the raw AWS JSON to an inline Python formatter via a heredoc to align headers perfectly.
2. **Tier 3 (jq + printf)**: If `python3` is missing but `jq` is available, it parses the JSON inside bash and renders using `printf`.
3. **Tier 4 (Raw Output)**: If neither is available, it prints a raw dump to stderr to avoid failing silently.

### 3. Smart SSH Access & Security Group Auto-Heal
Before starting an SSH session (`aictf aws shell`), `aictf` will:
1. Dynamically lookup the current public IP of the user (`curl -s -4 icanhazip.com`).
2. Verify if the security group of the instance permits incoming traffic on port 22 for this IP.
3. If it is blocked (e.g., your IP changed because of DHCP/VPN), it **automatically invokes `aictf aws access`**, which revokes any existing port 22 access rules (preventing ingress pollution) and authorizes the new IP exclusively. This ensures passwordless SSH never hangs or fails due to network configuration shifts.

### 4. Interactive Selectors
When choosing an instance or option, `aictf` uses `select_item`:
- It dynamically uses `fzf` if installed on the host for a beautiful interactive fuzzy search.
- It falls back gracefully to a robust native Bash `select` menu if `fzf` is absent.

### 5. Automated Bootstrap (Cloud-Init)
The `create` command spins up a `t2.micro`/`t3.micro` instance using the latest Debian 12 or Kali Linux AMI. Its user-data bootstrap script:
- Standardizes on user `admin` for Debian 12 and user `kali` for Kali Linux.
- Dynamically configures the APT source repository for Charmbracelet and installs `crush` & `gum` automatically.
- Injects the SSH public key and configures the `GEMINI_API_KEY`/AWS Bedrock environment variables system-wide `/etc/environment` and inside `.bashrc` so the agent box is instantly authenticated and ready.
