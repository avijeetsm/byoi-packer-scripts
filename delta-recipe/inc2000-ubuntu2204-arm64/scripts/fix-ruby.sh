#!/usr/bin/env bash
# Ruby on the Ubuntu 22.04 arm64 CI image: toolcache 3.2 -> 3.2.11, 3.3 -> 3.3.13, add 3.4.12;
# system ruby3.0 -> latest Ubuntu build.
# Defaults are not changed: /usr/bin/ruby stays the system Ruby, toolcache Rubies stay off PATH.
# Re-runnable: versions already installed are not downloaded again.
# Run as a sudo-capable user:  bash fix-ruby.sh
#   REMOVE_OLD=1   remove the superseded 3.2.x / 3.3.x toolcache versions (default 1)
set -uo pipefail

REMOVE_OLD=${REMOVE_OLD:-1}
RUBY_VERSIONS=(3.2.11 3.3.13 3.4.12)
PLATFORM=ubuntu-22.04-arm64

TC=/opt/hostedtoolcache
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
RESULTS=()
export DEBIAN_FRONTEND=noninteractive

step() { echo; echo "=== $*"; }
ok()   { RESULTS+=("OK    $1"); echo "OK: $1"; }
fail() { RESULTS+=("FAIL  $1"); echo "FAIL: $1" >&2; }
skip() { RESULTS+=("SKIP  $1"); echo "SKIP: $1"; }

. /etc/os-release
[[ ${VERSION_ID:-} == 22.04 && $(uname -m) == aarch64 ]] ||
    { echo "This script is for Ubuntu 22.04 aarch64, found ${PRETTY_NAME:-unknown} $(uname -m)" >&2; exit 1; }
sudo -n true 2>/dev/null || { echo "needs passwordless sudo" >&2; exit 1; }

default_before=$(readlink -f "$(command -v ruby)" 2>/dev/null)
owner=$(stat -c %U:%G "$TC/Ruby" 2>/dev/null || echo root:root)

# --- 1. toolcache Rubies from ruby/ruby-builder (one release per version) -------
for RV in "${RUBY_VERSIONS[@]}"; do
    step "Ruby $RV (toolcache)"
    ruby=$TC/Ruby/$RV/arm64/bin/ruby
    if [[ $("$ruby" -e 'print RUBY_VERSION' 2>/dev/null) == "$RV" && -e $TC/Ruby/$RV/arm64.complete ]]; then
        skip "ruby $RV already in $TC/Ruby/$RV"
    else
        asset=ruby-$RV-$PLATFORM.tar.gz
        digest=$(curl -fsSL "https://api.github.com/repos/ruby/ruby-builder/releases/tags/ruby-$RV" |
                 python3 -I -c "import json,sys; print(next((a.get('digest') or '') for a in json.load(sys.stdin)['assets'] if a['name']==sys.argv[1]))" "$asset" 2>/dev/null)
        if ! curl -fsSL -o "$WORK/$asset" "https://github.com/ruby/ruby-builder/releases/download/ruby-$RV/$asset"; then
            fail "ruby $RV download"; continue
        fi
        if [[ $digest == sha256:* ]]; then
            echo "${digest#sha256:}  $WORK/$asset" | sha256sum -c --quiet || { fail "ruby $RV sha256 mismatch"; continue; }
        else
            echo "WARN  no published digest for $asset"
        fi
        # The archive contains arm64/ (built with prefix /opt/hostedtoolcache/Ruby/<ver>/arm64)
        sudo rm -rf "$TC/Ruby/$RV"
        sudo mkdir -p "$TC/Ruby/$RV"
        sudo tar -xzf "$WORK/$asset" -C "$TC/Ruby/$RV"
        sudo touch "$TC/Ruby/$RV/arm64.complete"
        sudo chown -R "$owner" "$TC/Ruby/$RV"
        v=$("$ruby" -e 'print RUBY_VERSION' 2>/dev/null)
        [[ $v == "$RV" ]] && ok "$TC/Ruby/$RV/arm64 ruby $v, gem $("$TC/Ruby/$RV/arm64/bin/gem" --version)" ||
            { fail "ruby $RV reports '$v'"; continue; }
    fi
    if [[ $REMOVE_OLD == 1 ]]; then
        for old in "$TC"/Ruby/"${RV%.*}".*; do
            [[ -d $old && $(basename "$old") != "$RV" ]] && sudo rm -rf "$old" "$old.complete" && echo "removed $old"
        done
    fi
done

# --- 2. system Ruby 3.0 (apt) ----------------------------------------------------
step "system ruby3.0 (apt)"
mapfile -t pkgs < <(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${source:Package}\n' | awk '$1=="ii" && $3=="ruby3.0" {print $2}')
if (( ! ${#pkgs[@]} )); then
    skip "no ruby3.0 packages installed"
else
    sudo apt-get update -qq
    if sudo apt-get install -y -qq -o Dpkg::Options::=--force-confold --only-upgrade "${pkgs[@]}"; then
        for p in "${pkgs[@]}"; do ok "$p $(dpkg-query -W -f='${Version}' "$p")"; done
    else
        fail "apt upgrade of ruby3.0 packages"
    fi
fi

# --- 3. verify defaults unchanged --------------------------------------------------
step "verify"
default_after=$(readlink -f "$(command -v ruby)" 2>/dev/null)
[[ $default_after == "$default_before" ]] && ok "default ruby unchanged: ${default_after:-none} ($(ruby -e 'print RUBY_VERSION' 2>/dev/null))" ||
    fail "default ruby changed: $default_before -> $default_after"
echo "toolcache Ruby: $(ls "$TC/Ruby" 2>/dev/null | grep -v complete | tr '\n' ' ')"

echo; echo "===== Summary"
printf '%s\n' "${RESULTS[@]}"
printf '%s\n' "${RESULTS[@]}" | grep -q '^FAIL' && exit 1
exit 0
