#!/bin/bash -e
################################################################################
##  File:  install-tailscale.sh
##  Desc:  Install Tailscale and enable tailscaled
################################################################################

curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
systemctl is-enabled tailscaled
tailscale version
