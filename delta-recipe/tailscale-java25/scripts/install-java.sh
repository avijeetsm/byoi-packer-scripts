#!/bin/bash -e
################################################################################
##  File:  install-java.sh
##  Desc:  Install Java 25 (Eclipse Temurin) without changing the default
################################################################################

export DEBIAN_FRONTEND=noninteractive

JAVA_VERSION=25

# Detect architecture
ARCH=$(dpkg --print-architecture)
if [[ "$ARCH" == "amd64" ]]; then
    ARCH_LABEL="x64"
elif [[ "$ARCH" == "arm64" ]]; then
    ARCH_LABEL="arm64"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

# Add Adoptium PPA
wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor > /usr/share/keyrings/adoptium.gpg
echo "deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb/ $(lsb_release -cs) main" > /etc/apt/sources.list.d/adoptium.list

apt-get update
apt-get install -y temurin-${JAVA_VERSION}-jdk

# Set up environment variable (same as install-java-tools.sh)
JAVA_VERSION_PATH="/usr/lib/jvm/temurin-${JAVA_VERSION}-jdk-${ARCH}"
echo "JAVA_HOME_${JAVA_VERSION}_X64=${JAVA_VERSION_PATH}" >> /etc/environment

# Set up toolcache entry (same as install-java-tools.sh)
AGENT_TOOLSDIRECTORY="/opt/hostedtoolcache"
java_toolcache_path="${AGENT_TOOLSDIRECTORY}/Java_Temurin-Hotspot_jdk"

full_java_version=$(cat "${JAVA_VERSION_PATH}/release" | grep "^SEMANTIC" | cut -d "=" -f 2 | tr -d "\"" | tr "+" "-")
[[ -z ${full_java_version} ]] && full_java_version=$(${JAVA_VERSION_PATH}/bin/java -fullversion 2>&1 | tr -d "\"" | tr "+" "-" | awk '{print $4}')
[[ ${full_java_version} =~ ^[0-9]+- ]] && full_java_version=$(echo $full_java_version | sed -E 's/-/.0-/')
[[ ${full_java_version} =~ ^[0-9]+\.[0-9]+- ]] && full_java_version=$(echo $full_java_version | sed -E 's/-/.0-/')

java_toolcache_version_path="${java_toolcache_path}/${full_java_version}"
mkdir -p "${java_toolcache_version_path}"
touch "${java_toolcache_version_path}/${ARCH_LABEL}.complete"
ln -s ${JAVA_VERSION_PATH} "${java_toolcache_version_path}/${ARCH_LABEL}"

chmod -R 777 /usr/lib/jvm

# Verify
${JAVA_VERSION_PATH}/bin/java -version

# Cleanup
rm -f /etc/apt/sources.list.d/adoptium.list
rm -f /usr/share/keyrings/adoptium.gpg
apt-get clean
