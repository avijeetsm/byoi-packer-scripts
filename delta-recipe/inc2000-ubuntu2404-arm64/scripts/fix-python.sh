#!/usr/bin/env bash
# Python follow-ups to INC-2000 on the Ubuntu 24.04 arm64 CI image. Run after fix-emudhra.sh (it installs
# toolcache 3.13.17, whose bundled pip-26.2.2 wheel step 3 reuses).
#   1. Ubuntu security updates for the system Python packages (noble-security only)
#   2. Toolcache CPython 3.10/3.11/3.12 -> latest patch release, pip 26.2.2 in each
#   3. Bundled ensurepip wheel -> pip 26.2.2 in every 3.10+ Python, so new venvs get a pip whose
#      certifi has no G3/AAA (toolcache CPython + PyPy, Miniconda, /opt/az). Old files are kept
#      under /var/backups/inc2000/ensurepip. /opt/az is reset by the next azure-cli apt upgrade.
# Python 3.9 / PyPy 3.9 are out of support and left as is.
# Re-runnable: versions already installed and wheels already replaced are left alone.
# Run as a sudo-capable user:  bash fix-python.sh
#   REMOVE_OLD=1   remove the superseded toolcache patch versions (default 1)
set -uo pipefail

REMOVE_OLD=${REMOVE_OLD:-1}
PIP=26.2.2
PY_VERSIONS=(3.10.22 3.11.18 3.12.16)
WHEEL_SRC_PY=3.13.17
TEST_HOSTS="dv-g3b-emudhra dv-g3b-aaa-emudhra"

TC=/opt/hostedtoolcache
BACKUP=/var/backups/inc2000/ensurepip
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
RESULTS=()

step() { echo; echo "=== $*"; }
ok()   { RESULTS+=("OK    $1"); echo "OK: $1"; }
fail() { RESULTS+=("FAIL  $1"); echo "FAIL: $1" >&2; }
skip() { RESULTS+=("SKIP  $1"); echo "SKIP: $1"; }

. /etc/os-release
[[ ${VERSION_ID:-} == 24.04 && $(uname -m) == aarch64 ]] ||
    { echo "This script is for Ubuntu 24.04 aarch64, found ${PRETTY_NAME:-unknown} $(uname -m)" >&2; exit 1; }
sudo -n true 2>/dev/null || { echo "needs passwordless sudo" >&2; exit 1; }

# pip in a fresh venv must reject the emSign/AAA test hosts and still reach PyPI
check_venv() {   # $1 = interpreter
    local py=$1 v=$WORK/venv-$RANDOM r h
    if ! "$py" -m venv "$v" >/dev/null 2>&1; then fail "$py -m venv"; return; fi
    local vp; vp=$("$v/bin/python" -m pip --version 2>/dev/null | awk '{print $2}')
    [[ $vp == "$PIP" ]] && ok "$py new venv gets pip $vp" || fail "$py new venv gets pip ${vp:-?}"
    for h in $TEST_HOSTS; do
        # no -q: pip logs the SSL failure reason at INFO level
        r=$("$v/bin/python" -m pip download --no-deps --no-cache-dir --disable-pip-version-check \
              --retries 0 --timeout 15 -d "$WORK/dl" --index-url "https://$h.we-have-a-problem.com/simple/" \
              inc2000-probe 2>&1)
        grep -q CERTIFICATE_VERIFY_FAILED <<<"$r" && ok "  venv pip rejects $h" || fail "  venv pip did not reject $h"
    done
    "$v/bin/python" -m pip index versions certifi --disable-pip-version-check >/dev/null 2>&1 &&
        ok "  venv pip reaches pypi.org" || fail "  venv pip cannot reach pypi.org"
    rm -rf "$v"
}

# --- 1. system Python: Ubuntu security updates -----------------------------------
step "system Python packages (noble-security)"
sudo apt-get update -qq
mapfile -t pkgs < <(apt list --upgradable 2>/dev/null | grep -E '^(lib)?python3' | grep noble-security | cut -d/ -f1)
if (( ${#pkgs[@]} )); then
    echo "upgrading: ${pkgs[*]}"
    if sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade "${pkgs[@]}"; then
        left=$(apt list --upgradable 2>/dev/null | grep -E '^(lib)?python3' | grep -c noble-security)
        [[ $left == 0 ]] && ok "${#pkgs[@]} packages; python3.12 $(dpkg-query -W -f='${Version}' python3.12), python3-pip $(dpkg-query -W -f='${Version}' python3-pip)" ||
            fail "$left python security updates still pending"
    else
        fail "apt upgrade of system Python packages"
    fi
else
    skip "no pending python security updates"
fi
/usr/bin/python3 -c 'import ssl, urllib.request, json, cryptography' && ok "system python3 $(/usr/bin/python3 -V 2>&1 | cut -d' ' -f2) imports ssl/urllib/json/cryptography" ||
    fail "system python3 import check"

# --- 2. toolcache CPython 3.10 / 3.11 / 3.12 -> latest patch release --------------
manifest=$(curl -fsSL https://raw.githubusercontent.com/actions/python-versions/main/versions-manifest.json)
owner=$(stat -c %U:%G "$TC/Python" 2>/dev/null || echo root:root)
for PV in "${PY_VERSIONS[@]}"; do
    step "Python $PV (toolcache)"
    mm=${PV%.*}
    py=$TC/Python/$PV/arm64/bin/python3
    if [[ $("$py" --version 2>&1) == "Python $PV" ]]; then
        echo "python $PV already in $TC/Python/$PV"
    else
        pt=python-$PV-linux-24.04-arm64.tar.gz
        purl=$(python3 -I -c "import json,sys; print(next(f['download_url'] for r in json.load(sys.stdin) if r['version']=='$PV' for f in r['files'] if f['filename']=='$pt'))" <<<"$manifest")
        rm -rf "$WORK/py" && mkdir -p "$WORK/py"
        if [[ -n $purl ]] && curl -fsSL -o "$WORK/$pt" "$purl" && tar -xzf "$WORK/$pt" -C "$WORK/py"; then
            (cd "$WORK/py" && sudo AGENT_TOOLSDIRECTORY=$TC RUNNER_TOOL_CACHE=$TC bash ./setup.sh >/dev/null)
            sudo chown -R "$owner" "$TC/Python/$PV"
        else
            fail "python $PV download/extract (old version kept)"; continue
        fi
    fi
    v=$("$py" --version 2>&1)
    if [[ $v == "Python $PV" ]] &&
       sudo "$py" -m pip install -q --disable-pip-version-check --root-user-action=ignore --no-warn-script-location "pip==$PIP"; then
        sudo chown -R "$owner" "$TC/Python/$PV"
        ok "$v -> $TC/Python/$PV/arm64, pip $("$py" -m pip --version | awk '{print $2}')"
        if [[ $REMOVE_OLD == 1 ]]; then
            for old in "$TC"/Python/"$mm".*; do
                [[ -d $old && $(basename "$old") != "$PV" ]] && sudo rm -rf "$old" && echo "removed $old"
            done
        fi
    else
        fail "python $PV reports '$v' or pip upgrade failed (old version kept)"
    fi
done

# --- 3. ensurepip: bundle pip 26.2.2 so new venvs are clean ----------------------
step "ensurepip bundled pip -> $PIP"
src=$TC/Python/$WHEEL_SRC_PY/arm64/lib/python${WHEEL_SRC_PY%.*}/ensurepip/_bundled/pip-$PIP-py3-none-any.whl
want=$(curl -fsSL "https://pypi.org/pypi/pip/$PIP/json" |
       python3 -I -c "import json,sys; print(next(u['digests']['sha256'] for u in json.load(sys.stdin)['urls'] if u['filename']=='pip-$PIP-py3-none-any.whl'))")
have=$(sha256sum "$src" 2>/dev/null | cut -d' ' -f1)
if [[ -z $have || $have != "$want" ]]; then
    fail "source wheel $src missing (run fix-emudhra.sh first) or sha256 differs from PyPI (${have:-none} vs $want); step 3 not run"
else
    ok "source wheel matches PyPI sha256 ${want:0:16}..."
    for py in "$TC"/Python/*/arm64/bin/python3 "$TC"/PyPy/*/arm64/bin/python /usr/share/miniconda/bin/python3 /opt/az/bin/python3; do
        [[ -x $py ]] || continue
        if ! "$py" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
            skip "$py (Python < 3.10, out of support)"; continue
        fi
        ep=$("$py" -I -c 'import ensurepip, os; print(os.path.dirname(ensurepip.__file__))')
        cur=$("$py" -I -c 'import ensurepip; print(ensurepip.version())')
        if [[ $cur != "$PIP" ]]; then
            bk=$BACKUP/$(tr / _ <<<"${ep#/}")
            [[ -e $ep/_bundled/pip-$cur-py3-none-any.whl ]] || { fail "$py: $ep/_bundled/pip-$cur-py3-none-any.whl not found"; continue; }
            owner=$(stat -c %U:%G "$ep/__init__.py")
            sudo mkdir -p "$bk"
            [[ -e $bk/__init__.py ]] || sudo cp -p "$ep/__init__.py" "$bk/"
            sudo mv "$ep/_bundled/pip-$cur-py3-none-any.whl" "$bk/"
            sudo install -m 644 -o "${owner%:*}" -g "${owner#*:}" "$src" "$ep/_bundled/"
            sudo sed -i "s/^_PIP_VERSION = \"$cur\"/_PIP_VERSION = \"$PIP\"/" "$ep/__init__.py"
            sudo rm -f "$ep"/__pycache__/__init__.*.pyc
            echo "$py: ensurepip $cur -> $PIP (backup in $bk)"
        fi
        nv=$("$py" -I -c 'import ensurepip; print(ensurepip.version())')
        [[ $nv == "$PIP" ]] && ok "$py ensurepip $nv" || { fail "$py ensurepip still $nv"; continue; }
        check_venv "$py"
    done
fi

# setuptools that 3.10/3.11 venvs still get from ensurepip (not changed here)
for py in "$TC"/Python/3.1[01].*/arm64/bin/python3 "$TC"/PyPy/3.10.*/arm64/bin/python; do
    [[ -x $py ]] && echo "note: $py ensurepip setuptools $("$py" -I -c 'import ensurepip; print(ensurepip._SETUPTOOLS_VERSION)' 2>/dev/null)"
done

echo; echo "===== Summary"
printf '%s\n' "${RESULTS[@]}"
echo "toolcache Python: $(ls "$TC/Python" | grep -v complete | tr '\n' ' ')"
printf '%s\n' "${RESULTS[@]}" | grep -q '^FAIL' && exit 1
exit 0
