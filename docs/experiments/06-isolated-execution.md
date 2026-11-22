# EXP-006: Independent execution and isolation

**Status:** In progress. Local tmux prototype accepted (FIND-071/072 local; FIND-073 qualified). Kubernetes two-pod synthetic slice PASS in one G1 run (`s2a`, cleanup CLEAN; FIND-074 proposed). Real agent not tested.

First assess whether Herdr's session management can restart/upgrade independently from long-running agent processes through remote PTY/session attachment. Then test trusted remote agent pods and consider OpenShell/Kata policy, terminal integration, state restoration, and sandbox isolation. Do not assume native support for remote agent status/transcript detection or process migration without tests. Consider `agent-runner` reuse only after requirements emerge.

**Evidence:** [experiments/exp-006](../../experiments/exp-006/README.md): local attach, disconnect and reconnect, and clean and forced Herdr restarts, all reaching the same tmux-owned process (FIND-071..073). Kubernetes run `s2a`: the same process survived pane close and Herdr pod replacement ([evidence](../../experiments/exp-006/k8s/evidence/s2a/README.md), FIND-074). **Requirements:** REQ-009, REQ-011.
