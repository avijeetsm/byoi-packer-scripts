#!/bin/bash -e
################################################################################
##  File:  install-ruby.sh
##  Desc:  Install Ruby requirements and ruby gems
################################################################################

# Source the helpers for use with the script
source $HELPER_SCRIPTS/os.sh
source $HELPER_SCRIPTS/install.sh

apt-get install -y ruby-full

# Install ruby gems from toolset
gems_to_install=$(get_toolset_value ".rubygems[] .name")
if [[ -n "$gems_to_install" ]]; then
    for gem in $gems_to_install; do
        echo "Installing gem $gem"
        gem install --no-document $gem
    done
fi

# Install Ruby requirements
apt-get install -y libz-dev openssl libssl-dev

echo "Install Ruby from toolset..."
package_entries=$(curl -fsSL "https://api.github.com/repos/ruby/ruby-builder/releases?per_page=100" | jq -r '.[] | .assets[]? | "\(.name) \(.browser_download_url)"')
toolset_versions=$(get_toolset_value '.toolcache[] | select(.name | contains("Ruby")) | .versions[]')
platform_version=$(get_toolset_value '.toolcache[] | select(.name | contains("Ruby")) | .platform_version')
arch=$(get_toolset_value '.toolcache[] | select(.name | contains("Ruby")) | .arch')
ruby_path="$AGENT_TOOLSDIRECTORY/Ruby"

echo "Check if Ruby hostedtoolcache folder exist..."
if [[ ! -d $ruby_path ]]; then
    mkdir -p $ruby_path
fi

for toolset_version in ${toolset_versions[@]}; do
    toolset_version_pattern="${toolset_version//./\\.}"
    toolset_version_pattern="${toolset_version_pattern//\*/[0-9]+}"
    package_entry=$(echo "$package_entries" | grep -E "^ruby-${toolset_version_pattern}-ubuntu-${platform_version}-${arch}\.tar\.gz " | sort -V | tail -1)
    package_tar_name=$(echo "$package_entry" | awk '{print $1}')
    download_url=$(echo "$package_entry" | awk '{print $2}')

    if [[ -z "$download_url" ]]; then
        echo "Could not find Ruby toolcache package for version '${toolset_version}', Ubuntu '${platform_version}', arch '${arch}'"
        exit 1
    fi

    ruby_version=$(echo "$package_tar_name" | cut -d'-' -f 2)
    ruby_version_path="$ruby_path/$ruby_version"

    echo "Create Ruby $ruby_version directory..."
    mkdir -p $ruby_version_path

    echo "Downloading tar archive $package_tar_name"
    package_archive_path=$(download_with_retry "$download_url")

    echo "Expand '$package_tar_name' to the '$ruby_version_path' folder"
    tar xf "$package_archive_path" -C $ruby_version_path

    complete_file_path="$ruby_version_path/x64.complete"
    if [[ ! -f $complete_file_path ]]; then
        echo "Create complete file"
        touch $complete_file_path
    fi
done

invoke_tests "Tools" "Ruby"
