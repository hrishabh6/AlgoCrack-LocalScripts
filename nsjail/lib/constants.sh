#!/usr/bin/env bash
# Pinned artifacts for CXE NsJail Phase 1 (see context/cxe_persistent_nsjail_implementation_plan.md).

NSJAIL_VERSION="${NSJAIL_VERSION:-3.6}"
NSJAIL_GIT_REF="${NSJAIL_GIT_REF:-3.6}"

# SHA-256 of scripts/experiments/nsjail/seccomp-nsjail-setup.json (outer Localhost profile).
NSJAIL_OUTER_SECCOMP_SHA256="${NSJAIL_OUTER_SECCOMP_SHA256:-e33f73c8bb927a36da2a3c9c57a6b7cb19a8aa6617d41661da2f3a83afbf6874}"

NSJAIL_KUBELET_PROFILE_DIR="${NSJAIL_KUBELET_PROFILE_DIR:-/var/lib/kubelet/seccomp/profiles}"
NSJAIL_KUBELET_PROFILE_NAME="${NSJAIL_KUBELET_PROFILE_NAME:-nsjail-spike.json}"
NSJAIL_KUBELET_LOCALHOST_PROFILE="${NSJAIL_KUBELET_LOCALHOST_PROFILE:-profiles/${NSJAIL_KUBELET_PROFILE_NAME}}"

NSJAIL_SPIKE_NAMESPACE="${NSJAIL_SPIKE_NAMESPACE:-algocrack-nsjail-spike}"
NSJAIL_SPIKE_IMAGE="${NSJAIL_SPIKE_IMAGE:-algocrack/nsjail-spike:3.6}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
NSJAIL_EXPERIMENT_DIR="${SCRIPTS_ROOT}/experiments/nsjail"
NSJAIL_OUTER_SECCOMP_SOURCE="${NSJAIL_EXPERIMENT_DIR}/seccomp-nsjail-setup.json"
NSJAIL_CANARY_MANIFEST="${NSJAIL_EXPERIMENT_DIR}/pod-localhost-seccomp.yaml"

NSJAIL_INNER_POLICY="${NSJAIL_EXPERIMENT_DIR}/inner-syscall-policy-minimum.json"
NSJAIL_INNER_POLICY_SHA256="${NSJAIL_INNER_POLICY_SHA256:-8a0ebf7f99e98c520f7ede6566bac302ee88fc5e4635eff93f5fda0964617186}"
