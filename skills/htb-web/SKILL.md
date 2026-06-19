---
name: "htb-web"
description: "HackTheBox Web Challenge Assistant"
---

## Description
This skill is designed for enumerating, exploiting, and documenting web-based CTF challenges in HackTheBox and other security platforms. It guides the user conceptually through web vulnerabilities, executes required tool commands, and formats a clean, comprehensive penetration testing report/writeup of the challenge.

## Inputs & Parameters
* **Target IP**: The user will provide the target IP address in their prompt (e.g., "Use htb-web on 10.0.2.34"). Treat this as the target for all subsequent commands.
* **Missing Target**: If the user does not provide an IP address when invoking this skill, you must pause and ask them for it before suggesting any `nmap` or `gobuster` commands.

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
