#!/bin/bash -e
################################################################################
##  File:  docker-moby.sh
##  Desc:  Installs docker onto the image
################################################################################

# Source the helpers for use with the script
source $HELPER_SCRIPTS/install.sh

function install_moby {
    # Check to see if docker is already installed
    docker_package=moby
    echo "Determing if Docker ($docker_package) is installed"
    if ! IsPackageInstalled $docker_package; then
        echo "Docker ($docker_package) was not found. Installing..."
        apt-get remove -y moby-engine moby-cli
        apt-get update
        apt-get install -y moby-engine moby-cli
        apt-get install --no-install-recommends -y moby-buildx
        apt-get install -y moby-compose
    else
        echo "Docker ($docker_package) is already installed"
    fi
}

function install_docker {
    docker_package=docker

    echo "Docker ($docker_package) was not found. Installing..."
    apt-get remove -y docker-ce

    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | apt-key add -
    add-apt-repository "deb [arch=$(dpkg --print-architecture)] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable"
    apt-get update -y
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

install_docker

# Enable docker.service
systemctl is-active --quiet docker.service || systemctl start docker.service
systemctl is-enabled --quiet docker.service || systemctl enable docker.service

# Docker daemon takes time to come up after installing
sleep 10
docker info

# If credentials are provided, attempt to log into Docker Hub
# with a paid account to avoid Docker Hub's rate limit.
if [ "${DOCKERHUB_LOGIN}" ] && [ "${DOCKERHUB_PASSWORD}" ]; then
  docker login --username "${DOCKERHUB_LOGIN}" --password "${DOCKERHUB_PASSWORD}"
fi

# Pull images
images=$(get_toolset_value '.docker.images[]')
for image in $images; do
    docker pull "$image"
done

# Always attempt to logout so we do not leave our credentials on the built
# image. Logout _should_ return a zero exit code even if no credentials were
# stored from earlier.
docker logout

# Install amazon-ecr-credential-helper
aws_latest_release_url="https://api.github.com/repos/awslabs/amazon-ecr-credential-helper/releases/latest"
aws_helper_url=$(curl "${authString[@]}" -sL $aws_latest_release_url | jq -r '.body' | awk -F'[()]' '/linux-amd64/ {print $2}')
aws_helper_binary_path=$(download_with_retry "${aws_helper_url}")

install "$aws_helper_binary_path" /usr/bin/docker-credential-ecr-login
invoke_tests "Tools" "Docker"
