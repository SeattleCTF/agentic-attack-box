# Agentic Attack Box manager

`aictf` is a command-line tool designed to seamlessly manage ephemeral, cloud-based "attack boxes" pre-configured with security tools and AI coding agents. 

It handles the infrastructure, security groups, SSH keys, and cloud-init scripts entirely in the background, allowing you to spin up an AI-assisted pentesting environment with a single command.

## Prerequisites

- `curl`
- `make`
- `aws-cli` (configured and authenticated)
- `python3` (optional, for enhanced table rendering)

## Installation

Clone the repository and build the standalone executable:

```bash
git clone [https://github.com/yourusername/aictf.git](https://github.com/yourusername/aictf.git)
cd aictf
make install
```

This will bundle the source scripts and install the executable to `~/.local/bin/aictf`. Ensure `~/.local/bin` is in your `$PATH`.

## Quick Start Workflow

**1. Create a new attack box:**

```bash
aictf aws create

```

*This will automatically generate a passwordless SSH key pair in `~/.aictf/ssh-keys/`, prompt you for your LLM token if it's your first time, and spin up a free-tier Debian/Kali instance using your default AWS profile. The instance will bootstrap `crush`, Kali CLI tools, and `openvpn` via cloud-init.*

**2. Check the status:**

```bash
aictf list

```

*Output:*

```text
Provider | Instance ID         | Public IP      | Accessible | State
---------|---------------------|----------------|------------|-------
aws      | i-0abcd1234efgh5678 | 198.51.100.14  | ⛔         | ⏳

```

*Wait a few minutes for the state to transition from ⏳ (launching) to ✅ (running).*

**3. Shell into the box:**

```bash
aictf aws shell

```

*This command acts intelligently: it detects that the instance is not accessible (⛔) from your current IP, automatically updates the AWS Security Group to whitelist your IP, and drops you into the SSH session.*

**4. Use your AI Agent:**
Once inside the box, your LLM keys are already injected. Simply run:

```bash
crush "write a python script to scan the local subnet"

```

**5. Shut down:**
When you are done, exit the SSH session and stop the instance to save costs:

```bash
exit
aictf aws stop

```

## Command Reference

### Global

* `aictf help` - Show usage instructions.
* `aictf list` - List all tracked attack boxes, their accessibility, and lifecycle states.
* `aictf config [subcommand]` - Manage CLI configurations and profiles.

### Provider Specific (AWS)

* `aictf aws` - Show AWS configuration status.
* `aictf aws create` - Deploy a new instance.
* `aictf aws shell [id]` - Connect to an instance.
* `aictf aws start [id]` - Start a stopped instance.
* `aictf aws stop [id]` - Stop a running instance.
* `aictf aws destroy [id]` - Terminate an instance permanently.
* `aictf aws access [id]` - Manually update the Security Group to allow SSH from your current IP.

*(Note: `gcloud` and `oci` support are planned for future releases).*

## Data & State Management

All state, configurations, and secrets are stored locally in your home directory:

* `~/.aictf/config` - Profile configurations.
* `~/.aictf/ssh-keys/` - Automatically generated keys for instance access.
* `~/.aictf/llm-keys/` - Tokens for Bedrock/Gemini to power `crush`.
