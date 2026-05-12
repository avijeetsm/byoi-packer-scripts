#!/bin/bash -e
################################################################################
##  File:  install-container-tools.sh
##  Desc:  Install container tools: podman, buildah and skopeo onto the image
################################################################################

# Source the helpers for use with the script
source $HELPER_SCRIPTS/os.sh

#
# pin podman due to https://github.com/actions/runner-images/issues/7753
#                   https://bugs.launchpad.net/ubuntu/+source/libpod/+bug/2024394
#
if ! is_ubuntu22; then
    install_packages=(podman buildah skopeo)
else
    install_packages=(podman=3.4.4+ds1-1ubuntu1 buildah skopeo)
fi


if is_ubuntu22; then
    # Install containernetworking-plugins for Ubuntu 22
    curl -O http://archive.ubuntu.com/ubuntu/pool/universe/g/golang-github-containernetworking-plugins/containernetworking-plugins_1.1.1+ds1-3build1_amd64.deb
    dpkg -i containernetworking-plugins_1.1.1+ds1-3build1_amd64.deb
fi

# Install podman, buildah, skopeo container's tools
apt-get update
apt-get install ${install_packages[@]}
mkdir -p /etc/containers
printf "[registries.search]\nregistries = ['docker.io', 'quay.io']\n" | tee /etc/containers/registries.conf

# Configure subuid/subgid for all users to enable rootless podman networking.
# The install-time test runs as root (via sudo), but the final RunAll-Tests.ps1
# runs as the non-root packer SSH user which also needs these mappings.
subid_offset=100000
for user_entry in root $(awk -F: '$3 >= 1000 {print $1}' /etc/passwd); do
    if ! grep -q "^${user_entry}:" /etc/subuid 2>/dev/null; then
        echo "${user_entry}:${subid_offset}:65536" >> /etc/subuid
        echo "${user_entry}:${subid_offset}:65536" >> /etc/subgid
        subid_offset=$((subid_offset + 65536))
    fi
done

invoke_tests "Tools" "Containers"
