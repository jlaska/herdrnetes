# EXP-006: Independent execution and isolation

**Status:** Planned.

First assess whether Herdr's session management can restart/upgrade independently from long-running agent processes through remote PTY/session attachment. Then test trusted remote agent pods and consider OpenShell/Kata policy, terminal integration, state restoration, and sandbox isolation. Do not assume native support for remote agent status/transcript detection or process migration without tests. Consider `agent-runner` reuse only after requirements emerge.

**Evidence:** None yet. **Requirements:** REQ-009, REQ-011.
