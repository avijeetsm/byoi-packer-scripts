#!/usr/bin/env bash
# Add Go 1.26.10 and 1.27.3 to the toolcache and make 1.26.10 the default, on the Ubuntu 22.04 arm64 CI image.
# Mirrors Install-Toolset.ps1 / Configure-Toolset.ps1. Older Go versions in the toolcache are kept.
# Re-runnable: versions already installed are not downloaded again.
# Run as a sudo-capable user:  bash fix-go.sh
set -uo pipefail

GO_VERSIONS=(1.26.10 1.27.3)
GO_DEFAULT=1.26.10
MANIFEST=https://raw.githubusercontent.com/actions/go-versions/main/versions-manifest.json

TC=/opt/hostedtoolcache
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
RESULTS=()

step() { echo; echo "=== $*"; }
ok()   { RESULTS+=("OK    $1"); echo "OK: $1"; }
fail() { RESULTS+=("FAIL  $1"); echo "FAIL: $1" >&2; }
skip() { RESULTS+=("SKIP  $1"); echo "SKIP: $1"; }

. /etc/os-release
[[ ${VERSION_ID:-} == 22.04 && $(uname -m) == aarch64 ]] ||
    { echo "This script is for Ubuntu 22.04 aarch64, found ${PRETTY_NAME:-unknown} $(uname -m)" >&2; exit 1; }
sudo -n true 2>/dev/null || { echo "needs passwordless sudo" >&2; exit 1; }

owner=$(stat -c %U:%G "$TC/go" 2>/dev/null || echo root:root)

# --- 1. install into the toolcache ----------------------------------------------
for GV in "${GO_VERSIONS[@]}"; do
    step "Go $GV (toolcache)"
    go=$TC/go/$GV/arm64/bin/go
    if [[ $("$go" version 2>/dev/null | awk '{print $3}') == "go$GV" ]]; then
        skip "go $GV already in $TC/go/$GV"
    else
        [[ -s $WORK/manifest.json ]] || curl -fsSL -o "$WORK/manifest.json" "$MANIFEST"
        url=$(python3 -I -c "import json,sys; print(next(f['download_url'] for r in json.load(open(sys.argv[1])) if r['version']==sys.argv[2] for f in r['files'] if f['platform']=='linux' and f['arch']=='arm64'))" "$WORK/manifest.json" "$GV" 2>/dev/null)
        mkdir -p "$WORK/$GV"
        if [[ -n $url ]] && curl -fsSL -o "$WORK/go-$GV.tar.gz" "$url" && tar -xzf "$WORK/go-$GV.tar.gz" -C "$WORK/$GV"; then
            (cd "$WORK/$GV" && sudo AGENT_TOOLSDIRECTORY=$TC bash ./setup.sh >/dev/null)
            sudo chown -R "$owner" "$TC/go/$GV"
            v=$("$go" version 2>/dev/null | awk '{print $3}')
            [[ $v == "go$GV" ]] && ok "$TC/go/$GV/arm64 $v" || { fail "go $GV reports '$v'"; continue; }
        else
            fail "go $GV download/extract"; continue
        fi
    fi

    # GOROOT_<major>_<minor>_X64 in /etc/environment
    IFS=. read -r major minor _ <<< "$GV"
    var=GOROOT_${major}_${minor}_X64
    sudo sed -i "/^$var=/d" /etc/environment
    echo "$var=$TC/go/$GV/arm64" | sudo tee -a /etc/environment >/dev/null
done

# --- 2. default: /usr/bin symlinks (go, gofmt) -> GO_DEFAULT -----------------------
step "default Go $GO_DEFAULT"
if [[ -x $TC/go/$GO_DEFAULT/arm64/bin/go ]]; then
    for f in "$TC/go/$GO_DEFAULT/arm64/bin/"*; do
        sudo ln -sfn "$f" "/usr/bin/$(basename "$f")"
    done
    v=$(/usr/bin/go version | awk '{print $3}')
    [[ $v == "go$GO_DEFAULT" ]] && ok "default /usr/bin/go $v -> $(readlink -f /usr/bin/go)" || fail "default go is $v"
    echo "gofmt -> $(readlink -f /usr/bin/gofmt)"
else
    fail "go $GO_DEFAULT not installed, default not changed"
fi
grep '^GOROOT_' /etc/environment

echo; echo "===== Summary"
printf '%s\n' "${RESULTS[@]}"
printf '%s\n' "${RESULTS[@]}" | grep -q '^FAIL' && exit 1
exit 0
