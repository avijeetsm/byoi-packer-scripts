#!/usr/bin/env bash
# INC-2000 eMudhra / emSign CA incident (CVE-2026-111943) on the Ubuntu 24.04 arm64 CI image.
# Removes trust in emSign ECC Root CA - G3, AAA Certificate Services, emSign ECC Root CA - C3 and
# emSign Root CA - C1 (C3/C1: internal blocklist), and upgrades the components that ship their own copy.
#   1. ca-certificates + distrust C3/C1 in the OS store (Temurin JDKs follow via the adoptium hook)
#   2. CodeQL bundled JDKs -> linked to the OS Java store
#   3. Azure CLI (apt)
#   4. Node.js toolcache 22/24 + default node -> 24
#   5. Python toolcache 3.13, pip everywhere, Miniconda
#   6. AWS CLI v2, Google Cloud CLI, aws-sdk-core gem, Julia
# Re-runnable: components that are not installed are skipped, ones already at the target are left alone.
# Run fix-python.sh after this script (it reuses the pip wheel bundled with Python 3.13 from step 5).
# Run as a sudo-capable user:  bash fix-emudhra.sh
#   REMOVE_OLD=1   remove the superseded versions (default 1) so their bundled roots are gone
set -uo pipefail

REMOVE_OLD=${REMOVE_OLD:-1}

CA_MIN=20260816ubuntu0.24.04.1
NODE_VERSIONS=(22.23.4 24.22.1)
NODE_DEFAULT=24.22.1
PIP=26.2.2
PY313=3.13.17
AWSCLI=2.38.5
GCLOUD_MIN=590.0.1
CONDA_CA=2026.10.20
CONDA_CERTIFI=2026.10.23
CERTIFI_MIN=2026.10.23   # first certifi without emSign C3/C1
AWS_SDK_CORE=3.260.0
JULIA=1.13.3
# SHA-256 of the blocked roots: emSign ECC G3 | AAA Certificate Services | emSign ECC C3 | emSign C1
BAD_ROOTS="86:A1:EC:BA:08:9C:4A:8D:3B:BE:27:34:C6:12:BA:34:1D:81:3E:04:3C:F9:E8:A8:62:CD:5C:57:A3:6B:BE:6B|D7:A7:A0:FB:5D:7E:27:31:D7:71:E9:48:4E:BC:DE:F7:1D:5F:0C:3E:0A:29:48:78:2B:C8:3E:E0:EA:69:9E:F4|BC:4D:80:9B:15:18:9D:78:DB:3E:1D:8C:F4:F9:72:6A:79:5D:A1:64:3C:A5:F1:35:8E:1D:DB:0E:DC:0D:7E:B3|12:56:09:AA:30:1D:A0:A2:49:B9:7A:82:39:CB:6A:34:21:6F:44:DC:AC:9F:39:54:B1:42:92:F2:E8:C8:60:8F"
TEST_HOSTS="dv-g3b-emudhra dv-g3b-aaa-emudhra dv-g3b-noct-emudhra dv-g3b-aaa-noct-emudhra"

TC=/opt/hostedtoolcache
JAVA_STORE=/etc/ssl/certs/adoptium/cacerts
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

# number of blocked roots in a PEM bundle / a Java keystore
bad_pem() {
    python3 -I -c '
import re, ssl, hashlib, sys
bad = set(sys.argv[2].replace(":", "").lower().split("|"))
pems = re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", open(sys.argv[1]).read(), re.S)
print(sum(hashlib.sha256(ssl.PEM_cert_to_DER_cert(p)).hexdigest() in bad for p in pems))' "$1" "$BAD_ROOTS"
}
keytool=$(ls /usr/lib/jvm/*/bin/keytool 2>/dev/null | head -1)
bad_jks() { sudo "$keytool" -list -v -keystore "$1" -storepass changeit 2>/dev/null | grep -cE "SHA256: ($BAD_ROOTS)" || true; }

# --- 1. OS trust store ------------------------------------------------------------
step "ca-certificates >= $CA_MIN (USN-8944-1)"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade ca-certificates
v=$(dpkg-query -W -f='${Version}' ca-certificates)
dpkg --compare-versions "$v" ge "$CA_MIN" && ok "ca-certificates $v" || fail "ca-certificates $v < $CA_MIN"

# Ubuntu's ca-certificates update removed only G3 and AAA. A "!" line in /etc/ca-certificates.conf
# survives package upgrades; update-ca-certificates rebuilds ca-certificates.crt and runs the
# adoptium-cacerts hook, so the Temurin JDKs pick it up too.
step "OS trust store: distrust emSign C3 / C1"
[[ -e /etc/ca-certificates.conf.inc2000.bak ]] || sudo cp -p /etc/ca-certificates.conf /etc/ca-certificates.conf.inc2000.bak
for crt in mozilla/emSign_ECC_Root_CA_-_C3.crt mozilla/emSign_Root_CA_-_C1.crt; do
    if grep -qxF "$crt" /etc/ca-certificates.conf; then
        sudo sed -i "s|^${crt}\$|!${crt}|" /etc/ca-certificates.conf
    elif ! grep -qxF "!$crt" /etc/ca-certificates.conf; then
        echo "!$crt" | sudo tee -a /etc/ca-certificates.conf >/dev/null
    fi
done
sudo update-ca-certificates
n=$(bad_pem /etc/ssl/certs/ca-certificates.crt)
[[ $n == 0 ]] && ok "ca-certificates.crt has none of G3/AAA/C3/C1" || fail "ca-certificates.crt still has $n blocked root(s)"
if [[ -n $keytool && -s $JAVA_STORE ]]; then
    n=$(bad_jks "$JAVA_STORE")
    [[ $n == 0 ]] && ok "$JAVA_STORE (all Temurin JDKs) has none of G3/AAA/C3/C1" || fail "$JAVA_STORE still has $n blocked root(s)"
else
    skip "no Temurin JDK / $JAVA_STORE"
fi

# --- 2. CodeQL bundled JDKs -> OS Java store -----------------------------------------
# The CodeQL bundle ships two JDKs with their own cacerts. Each one that still trusts a blocked
# root is replaced by a link to the store checked above; the original is kept as cacerts.inc2000.orig.
step "CodeQL bundled JDK cacerts"
found=0
for cacerts in "$TC"/CodeQL/*/arm64/codeql/tools/linux64/java/lib/security/cacerts \
               "$TC"/CodeQL/*/arm64/codeql/java/tools/linux64/jdk-extractor-java/lib/security/cacerts; do
    [[ -e $cacerts ]] || continue
    found=1
    if [[ -z $keytool || ! -s $JAVA_STORE ]] || [[ $(bad_jks "$JAVA_STORE") != 0 ]]; then
        fail "$cacerts: $JAVA_STORE missing or not clean, not linked"; continue
    fi
    if [[ ! -L $cacerts && $(bad_jks "$cacerts") != 0 ]]; then
        [[ -e $cacerts.inc2000.orig ]] || sudo cp -p "$cacerts" "$cacerts.inc2000.orig"
        sudo ln -sfn "$JAVA_STORE" "$cacerts"
        echo "linked $cacerts -> $JAVA_STORE"
    fi
    n=$(bad_jks "$cacerts")
    [[ $n == 0 ]] && ok "$cacerts has no blocked roots" || fail "$cacerts still has $n blocked root(s)"
done
[[ $found == 1 ]] || skip "no CodeQL bundle in $TC/CodeQL"

# --- 3. Azure CLI (apt) --------------------------------------------------------------
# Latest az still pins certifi 2024.7.4; step 5 upgrades certifi/pip inside /opt/az,
# so this must run first (an apt upgrade replaces /opt/az).
step "Azure CLI (apt, latest)"
if dpkg -s azure-cli >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade azure-cli &&
        ok "azure-cli $(dpkg-query -W -f='${Version}' azure-cli)" || fail "azure-cli apt upgrade"
else
    skip "azure-cli not installed"
fi

# --- 4. Node.js ----------------------------------------------------------------------
for NV in "${NODE_VERSIONS[@]}"; do
    step "Node.js $NV (toolcache)"
    dest=$TC/node/$NV/arm64
    if [[ $("$dest/bin/node" --version 2>/dev/null) == "v$NV" && -e $TC/node/$NV/arm64.complete ]]; then
        skip "node $NV already in $dest"
    else
        tarball=node-v$NV-linux-arm64.tar.xz
        if curl -fsSL -o "$WORK/$tarball" "https://nodejs.org/dist/v$NV/$tarball" &&
           curl -fsSL -o "$WORK/SHASUMS256-$NV.txt" "https://nodejs.org/dist/v$NV/SHASUMS256.txt" &&
           (cd "$WORK" && grep " $tarball\$" "SHASUMS256-$NV.txt" | sha256sum -c --quiet); then
            sudo rm -rf "$dest" && sudo mkdir -p "$dest"
            sudo tar -xJf "$WORK/$tarball" -C "$dest" --strip-components=1
            sudo touch "$TC/node/$NV/arm64.complete"
            [[ $("$dest/bin/node" --version) == "v$NV" ]] && ok "node $NV -> $dest" || { fail "node $NV install did not verify"; continue; }
        else
            fail "node $NV download/checksum"; continue
        fi
    fi
    if [[ $REMOVE_OLD == 1 ]]; then
        for old in "$TC"/node/"${NV%%.*}".*; do
            [[ -d $old && $(basename "$old") != "$NV" ]] && sudo rm -rf "$old" && echo "removed $old"
        done
    fi
done

# Default /usr/local/bin/node is installed by `n`, as the image does. The toolcache copy above
# (checked against nodejs.org SHASUMS256) seeds n's cache, so n --offline downloads nothing.
# Global npm packages in /usr/local/lib/node_modules are kept; npm and corepack become Node 24's own.
# Rollback: sudo n --offline <previous version>   (n keeps it in /usr/local/n/versions/node)
step "default Node.js $NODE_DEFAULT"
src=$TC/node/$NODE_DEFAULT/arm64
before=$(/usr/local/bin/node --version 2>/dev/null)
if ! command -v n >/dev/null; then
    skip "n not installed, default node $before left as is"
elif [[ $before == "v$NODE_DEFAULT" ]]; then
    skip "default node already $before"
elif [[ $("$src/bin/node" --version 2>/dev/null) != "v$NODE_DEFAULT" ]]; then
    fail "$src is not node $NODE_DEFAULT, default node $before left as is"
else
    cache=/usr/local/n/versions/node/$NODE_DEFAULT
    sudo rm -rf "$cache" && sudo mkdir -p "$cache" && sudo cp -a "$src"/. "$cache"/
    if sudo n --offline "$NODE_DEFAULT" >/dev/null; then
        hash -r
        # Same permissions install-nodejs.sh sets, so regular users can still npm install -g
        sudo chmod -R 777 /usr/local/lib/node_modules /usr/local/bin
        ok "default node ${before:-none} -> $(/usr/local/bin/node --version)"
    else
        fail "n --offline $NODE_DEFAULT"
    fi
fi
if [[ $(/usr/local/bin/node --version 2>/dev/null) == "v$NODE_DEFAULT" ]]; then
    cmp -s /usr/local/bin/node "$src/bin/node" && ok "default node binary identical to $src/bin/node" ||
        fail "/usr/local/bin/node differs from $src/bin/node"
    ok "npm $(npm --version), npx $(npx --version), corepack $(corepack --version 2>/dev/null || echo n/a)"
    # Global CLIs the image installs. bazelisk is not run: it would download Bazel.
    for c in grunt gulp lerna newman parcel tsc webpack-cli yarn; do
        command -v "$c" >/dev/null || continue
        out=$(timeout 60 "$c" --version 2>&1 | tail -1) && ok "  $c $out" || fail "  $c --version: $out"
    done
    if [[ -d /usr/local/lib/node_modules/parcel/node_modules/@parcel/watcher ]]; then
        node -e 'require("/usr/local/lib/node_modules/parcel/node_modules/@parcel/watcher")' 2>/dev/null &&
            ok "  parcel native watcher loads" || fail "  parcel native watcher does not load"
    fi
    # Node's built-in root store must reject the test chains and still reach google.com
    probe='require("https").get(process.argv[1],{timeout:10000},r=>{console.log("T");process.exit(0)}).on("error",e=>{console.log(/certificate|issuer/i.test(e.message)?"R":"E:"+e.code);process.exit(0)})'
    for h in $TEST_HOSTS; do
        r=$(node -e "$probe" "https://$h.we-have-a-problem.com/")
        [[ $r == R ]] && ok "  node rejects $h" || fail "  node $h -> $r"
    done
    r=$(node -e "$probe" https://www.google.com/)
    [[ $r == T ]] && ok "  node reaches google.com" || fail "  node google.com -> $r"
fi

# --- 5. Python ---------------------------------------------------------------------
# 3.13.17's ensurepip bundles pip 26.2.2, so new 3.13 venvs are clean
step "Python $PY313 (toolcache)"
py=$TC/Python/$PY313/arm64/bin/python3
if [[ $("$py" --version 2>&1) == "Python $PY313" ]]; then
    skip "python $PY313 already in $TC/Python/$PY313"
else
    pt=python-$PY313-linux-24.04-arm64.tar.gz
    purl=$(curl -fsSL https://raw.githubusercontent.com/actions/python-versions/main/versions-manifest.json |
           python3 -I -c "import json,sys; print(next(f['download_url'] for r in json.load(sys.stdin) if r['version']=='$PY313' for f in r['files'] if f['filename']=='$pt'))")
    if [[ -n $purl ]] && curl -fsSL -o "$WORK/$pt" "$purl" && mkdir -p "$WORK/py" && tar -xzf "$WORK/$pt" -C "$WORK/py"; then
        owner=$(stat -c %U:%G "$TC/Python" 2>/dev/null || echo root:root)
        (cd "$WORK/py" && sudo AGENT_TOOLSDIRECTORY=$TC RUNNER_TOOL_CACHE=$TC bash ./setup.sh >/dev/null)
        sudo chown -R "$owner" "$TC/Python/$PY313"
        v=$("$py" --version 2>&1)
        [[ $v == "Python $PY313" ]] && ok "$v -> $TC/Python/$PY313/arm64" || fail "python $PY313 reports '$v'"
    else
        fail "python $PY313 download/extract"
    fi
fi
if [[ $REMOVE_OLD == 1 && $("$py" --version 2>&1) == "Python $PY313" ]]; then
    for old in "$TC"/Python/3.13.*; do
        [[ -d $old && $(basename "$old") != "$PY313" ]] && sudo rm -rf "$old" && echo "removed $old"
    done
fi

# pip 26.2.2 everywhere pip vendors its own certifi. Python 3.9 is out of support and left as is
# (the last pip for 3.9 still carries emSign G3). certifi is upgraded only where it is already installed.
step "pip $PIP (toolcache, PyPy, pipx shared + venvs, /opt/az)"
for py in "$TC"/Python/*/arm64/bin/python3 "$TC"/PyPy/*/arm64/bin/python /opt/pipx/shared/bin/python /opt/pipx/venvs/*/bin/python /opt/az/bin/python3; do
    [[ -x $py ]] || continue
    if ! "$py" -c 'import sys; sys.exit(sys.version_info < (3, 10))'; then
        skip "$py (Python < 3.10, out of support)"; continue
    fi
    pkgs=("pip==$PIP")
    "$py" -c 'import certifi' 2>/dev/null && pkgs+=("certifi>=$CERTIFI_MIN")
    owner=$(stat -c %U:%G "$py")
    if sudo "$py" -m pip install -q --disable-pip-version-check --root-user-action=ignore \
            --no-warn-script-location "${pkgs[@]}"; then
        [[ $py == "$TC"/* ]] && sudo chown -R "$owner" "${py%/arm64/bin/*}"
        c=$("$py" -c 'import certifi; print(" certifi", certifi.__version__)' 2>/dev/null)
        ok "$py pip $("$py" -m pip --version | awk '{print $2}')$c"
    else
        fail "$py pip upgrade"
    fi
done

step "Miniconda ca-certificates >= $CONDA_CA, certifi >= $CONDA_CERTIFI, pip $PIP"
CONDA=/usr/share/miniconda/bin/conda
if [[ -x $CONDA ]]; then
    if sudo "$CONDA" install -n base -y -q "ca-certificates>=$CONDA_CA" "certifi>=$CONDA_CERTIFI" "pip=$PIP" >/dev/null; then
        ok "conda $("$CONDA" list -n base 2>/dev/null | awk '$1=="ca-certificates"||$1=="certifi"||$1=="pip"{printf "%s=%s ", $1, $2}')"
    else
        fail "conda install"
    fi
else
    skip "Miniconda not installed"
fi

# --- 6. other tools with their own CA bundle ------------------------------------------
# AWS CLI v2: AAA removed in 2.38.4
step "AWS CLI $AWSCLI"
if ! command -v aws >/dev/null; then
    skip "aws cli not installed"
elif [[ $(aws --version 2>&1 | awk '{print $1}') == "aws-cli/$AWSCLI" ]]; then
    skip "aws-cli/$AWSCLI already installed"
elif curl -fsSL -o "$WORK/awscli.zip" "https://awscli.amazonaws.com/awscli-exe-linux-aarch64-$AWSCLI.zip" &&
     unzip -q "$WORK/awscli.zip" -d "$WORK" && sudo "$WORK/aws/install" --update >/dev/null; then
    v=$(aws --version 2>&1 | awk '{print $1}')
    [[ $v == "aws-cli/$AWSCLI" ]] && ok "$v" || fail "aws reports $v"
else
    fail "aws cli $AWSCLI download/install"
fi
if [[ $REMOVE_OLD == 1 && -d /usr/local/aws-cli/v2/$AWSCLI ]]; then
    for old in /usr/local/aws-cli/v2/*/; do
        n=$(basename "$old"); [[ $n != current && $n != "$AWSCLI" ]] && sudo rm -rf "$old" && echo "removed $old"
    done
fi

step "Google Cloud CLI >= $GCLOUD_MIN"
if dpkg -s google-cloud-cli >/dev/null 2>&1; then
    v=$(dpkg-query -W -f='${Version}' google-cloud-cli)
    if ! dpkg --compare-versions "$v" ge "$GCLOUD_MIN"; then
        # The image removes the Google repo after build: add it back only for this upgrade.
        GKEY=/usr/share/keyrings/cloud.google.gpg
        GLIST=/etc/apt/sources.list.d/google-cloud-sdk.list
        curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | sudo gpg --batch --yes --dearmor -o "$GKEY"
        echo "deb [signed-by=$GKEY] https://packages.cloud.google.com/apt cloud-sdk main" | sudo tee "$GLIST" >/dev/null
        sudo apt-get update -qq -o Dir::Etc::sourcelist="$GLIST" -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0
        sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --only-upgrade google-cloud-cli
        sudo rm -f "$GLIST" "$GKEY"
        v=$(dpkg-query -W -f='${Version}' google-cloud-cli)
    fi
    dpkg --compare-versions "$v" ge "$GCLOUD_MIN" && ok "google-cloud-cli (apt) $v" || fail "google-cloud-cli (apt) $v < $GCLOUD_MIN"
fi
if snap list google-cloud-cli >/dev/null 2>&1; then
    sudo snap refresh google-cloud-cli core22
    v=$(snap list google-cloud-cli | awk 'NR==2{print $2}')
    dpkg --compare-versions "$v" ge "$GCLOUD_MIN" && ok "google-cloud-cli (snap) $v" || fail "google-cloud-cli (snap) $v < $GCLOUD_MIN"
    ok "core22 (snap) $(snap list core22 | awk 'NR==2{print $2}')"
fi
dpkg -s google-cloud-cli >/dev/null 2>&1 || snap list google-cloud-cli >/dev/null 2>&1 || skip "google-cloud-cli not installed"

# aws-sdk-core 3.260.0 (excon 1.8.0 would need Ruby >= 3.3: not done)
step "gem aws-sdk-core $AWS_SDK_CORE"
if ! command -v gem >/dev/null || ! gem list -i '^aws-sdk-core$' >/dev/null; then
    skip "aws-sdk-core gem not installed"
else
    if gem list -i '^aws-sdk-core$' -v "$AWS_SDK_CORE" >/dev/null; then
        skip "aws-sdk-core $AWS_SDK_CORE already installed"
    elif sudo gem install aws-sdk-core -v "$AWS_SDK_CORE" --no-document -q; then
        ok "aws-sdk-core $AWS_SDK_CORE"
    else
        fail "gem aws-sdk-core $AWS_SDK_CORE"
    fi
    if [[ $REMOVE_OLD == 1 ]] && gem list -i '^aws-sdk-core$' -v "$AWS_SDK_CORE" >/dev/null; then
        for old in $(gem list '^aws-sdk-core$' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | grep -vx "$AWS_SDK_CORE"); do
            sudo gem uninstall aws-sdk-core -v "$old" -I -x && echo "removed aws-sdk-core $old"
        done
    fi
fi

# Julia 1.13.3 (MozillaCACerts 2026.10.20)
step "Julia $JULIA"
if ! command -v julia >/dev/null; then
    skip "julia not installed"
elif [[ $(julia --version) == "julia version $JULIA" ]]; then
    skip "julia $JULIA already installed"
else
    jt=julia-$JULIA-linux-aarch64.tar.gz
    if curl -fsSL -o "$WORK/$jt" "https://julialang-s3.julialang.org/bin/linux/aarch64/${JULIA%.*}/$jt" &&
       curl -fsSL -o "$WORK/julia.sha256" "https://julialang-s3.julialang.org/bin/checksums/julia-$JULIA.sha256" &&
       (cd "$WORK" && grep " $jt\$" julia.sha256 | sha256sum -c --quiet); then
        sudo rm -rf "/usr/local/julia$JULIA" && sudo mkdir -p "/usr/local/julia$JULIA"
        sudo tar -xzf "$WORK/$jt" -C "/usr/local/julia$JULIA" --strip-components=1
        link=$(command -v julia)
        sudo ln -sf "/usr/local/julia$JULIA/bin/julia" "$link"
        hash -r
        v=$(julia --version)
        [[ $v == "julia version $JULIA" ]] && ok "$v ($link)" || fail "julia reports $v"
    else
        fail "julia $JULIA download/checksum"
    fi
fi
if [[ $REMOVE_OLD == 1 && $(julia --version 2>/dev/null) == "julia version $JULIA" ]]; then
    for old in /usr/local/julia*; do
        [[ $old != "/usr/local/julia$JULIA" ]] && sudo rm -rf "$old" && echo "removed $old"
    done
fi

# --- summary ------------------------------------------------------------------------
echo; echo "===== Summary"
printf '%s\n' "${RESULTS[@]}"
printf '%s\n' "${RESULTS[@]}" | grep -q '^FAIL' && exit 1
exit 0
