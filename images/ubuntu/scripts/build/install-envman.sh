#!/bin/bash -e
################################################################################
##  File:  envman.sh
##  Desc:  Installs Envman
################################################################################

# Source the helpers for use with the script
source $HELPER_SCRIPTS/install.sh

ENVMAN_URL="https://github.com/bitrise-io/envman/releases/download/2.4.0/envman-Linux-x86_64"
envman_binary_path=$(download_with_retry "${ENVMAN_URL}")

# Mark it as executable
install "$envman_binary_path" /usr/local/bin/envman

invoke_tests "Tools" "envman"
