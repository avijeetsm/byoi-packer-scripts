#!/usr/bin/env bash
# php2shell (CVE-2026-109618, CVE-2026-109619): upgrade php8.1 to the Ubuntu fixed build (USN-8948-1)
# on the Ubuntu 22.04 arm64 CI image. Re-runnable: does nothing if PHP is missing or already fixed.
# Run as a sudo-capable user:  bash fix-php.sh
set -uo pipefail

PHP=8.1
PHP_MIN=8.1.2-1ubuntu2.28
export DEBIAN_FRONTEND=noninteractive
RESULTS=()

step() { echo; echo "=== $*"; }
ok()   { RESULTS+=("OK    $1"); echo "OK: $1"; }
fail() { RESULTS+=("FAIL  $1"); echo "FAIL: $1" >&2; }
skip() { RESULTS+=("SKIP  $1"); echo "SKIP: $1"; }

. /etc/os-release
[[ ${VERSION_ID:-} == 22.04 && $(uname -m) == aarch64 ]] ||
    { echo "This script is for Ubuntu 22.04 aarch64, found ${PRETTY_NAME:-unknown} $(uname -m)" >&2; exit 1; }
sudo -n true 2>/dev/null || { echo "needs passwordless sudo" >&2; exit 1; }

# --- 1. upgrade every binary package built from the php8.3 source ----------------
step "php$PHP >= $PHP_MIN"
mapfile -t pkgs < <(dpkg-query -W -f='${db:Status-Abbrev} ${binary:Package} ${source:Package}\n' | awk -v s="php$PHP" '$1=="ii" && $3==s {print $2}')
if (( ! ${#pkgs[@]} )); then
    skip "no php$PHP packages installed"
else
    echo "${pkgs[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y -qq -o Dpkg::Options::=--force-confold --only-upgrade "${pkgs[@]}" || fail "apt upgrade of php$PHP packages"
    if systemctl is-active --quiet "php$PHP-fpm"; then
        sudo systemctl restart "php$PHP-fpm" && ok "php$PHP-fpm restarted" || fail "php$PHP-fpm restart"
    fi

    # --- 2. verify -------------------------------------------------------------
    step "verify"
    low=0
    for p in "${pkgs[@]}"; do
        v=$(dpkg-query -W -f='${Version}' "$p")
        dpkg --compare-versions "$v" ge "$PHP_MIN" || { fail "$p $v < $PHP_MIN"; low=1; }
    done
    [[ $low == 0 ]] && ok "${#pkgs[@]} php$PHP packages >= $PHP_MIN"
    if command -v php >/dev/null; then
        errs=$(php -d display_startup_errors=1 -r '' 2>&1)
        [[ -z $errs ]] && ok "no extension load errors" || fail "extension load errors: $errs"
        echo "Xdebug: $(php -m | grep -qx Xdebug && echo enabled || echo disabled)   PCOV: $(php -m | grep -qx pcov && echo enabled || echo disabled)"
    fi
fi

echo; echo "===== Summary"
printf '%s\n' "${RESULTS[@]}"
printf '%s\n' "${RESULTS[@]}" | grep -q '^FAIL' && exit 1
exit 0
