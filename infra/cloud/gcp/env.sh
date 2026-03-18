#!/usr/bin/env bash
export PROJECT_ID="tam-challenge-490102"
export REGION="us-west1"
export ZONE="us-west1-b"
export SSH_PUBLIC_KEY_FILE="${HOME}/.ssh/id_ed25519.pub"
export MACHINE_TYPE="e2-small"

# Optional override. Defaults to CONTROL_PLANE_DISK_GB from config/cluster.env.
# export DISK_SIZE_GB="20GB"
