# EXP-006: Independent execution and isolation

**Status:** In progress. Local tmux prototype passed. The Kubernetes slice is proposed, but not prepared or approved (G1).

First assess whether Herdr's session management can restart/upgrade independently from long-running agent processes through remote PTY/session attachment. Then test trusted remote agent pods and consider OpenShell/Kata policy, terminal integration, state restoration, and sandbox isolation. Do not assume native support for remote agent status/transcript detection or process migration without tests. Consider `agent-runner` reuse only after requirements emerge.

**Evidence:** [experiments/exp-006](../../experiments/exp-006/README.md): local attach, disconnect and reconnect, and clean and forced Herdr restarts, all reaching the same tmux-owned process (FIND-071..073, proposed). **Requirements:** REQ-009, REQ-011.
