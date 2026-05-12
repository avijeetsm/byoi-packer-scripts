#!/bin/bash -e
################################################################################
##  File:  install-tailscale.sh
##  Desc:  Install Tailscale and enable tailscaled
################################################################################

# Source the helpers for use with the script
source $HELPER_SCRIPTS/install.sh

# Install Tailscale from the official installer.
curl -fsSL https://tailscale.com/install.sh | sh

# Enable tailscaled so VMs booted from this image start the daemon automatically.
systemctl enable --now tailscaled
systemctl is-enabled tailscaled
tailscale version
