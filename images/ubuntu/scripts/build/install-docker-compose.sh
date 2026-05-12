#!/bin/bash -e
################################################################################
##  File:  docker-compose.sh
##  Desc:  Installs Docker Compose
################################################################################

# Install docker-compose v1 from releases
source $HELPER_SCRIPTS/install.sh
URL="https://github.com/docker/compose/releases/download/1.29.2/docker-compose-Linux-x86_64"
docker_composr_binary_path=$(download_with_retry "${URL}")
install "$docker_composr_binary_path" /usr/local/bin/docker-compose
invoke_tests "Tools" "Docker-compose v1"
