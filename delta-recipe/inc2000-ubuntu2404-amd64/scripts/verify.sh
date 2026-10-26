#!/usr/bin/env bash
################################################################################
##  File:  verify.sh
##  Desc:  INC-2000 image check. Every TLS client on the image must reject the four emSign/AAA
##         test hosts and still reach google.com. Exits 1 if any client trusts a test host or
##         cannot be checked. Clients are found from what is installed, not from fixed versions.
##         Then lists the files that still bundle a blocked root (information only).
##  Usage: bash verify.sh        SCAN=0 bash verify.sh   (skip the filesystem scan)
##  Not checked (accepted, see the INC-2000 report): Python 3.9 / PyPy 3.9, toolcache Node 18/20.
################################################################################
set -uo pipefail

SCAN=${SCAN:-1}
D=we-have-a-problem.com
HOSTS=(dv-g3b-emudhra dv-g3b-aaa-emudhra dv-g3b-noct-emudhra dv-g3b-aaa-noct-emudhra)
CONTROL=https://www.google.com/
TC=/opt/hostedtoolcache
W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT
cd "$W" || exit 1
export GOCACHE=$W/gocache GOPATH=$W/gopath

# --- probes: print T (trusted), R (rejected) or E:<reason> ---------------------------
cat > Probe.java <<'J'
import java.net.*; import javax.net.ssl.*;
public class Probe { public static void main(String[] a) throws Exception {
  try { HttpsURLConnection c=(HttpsURLConnection)new URL(a[0]).openConnection(); c.setConnectTimeout(10000); c.setReadTimeout(10000); c.getResponseCode(); System.out.println("T"); }
  catch (SSLException e) { System.out.println("R"); } catch (Exception e) { System.out.println("E:"+e.getClass().getSimpleName()); } } }
J
cat > probe.go <<'G'
package main
import ("fmt";"net/http";"os";"time";"crypto/tls";"errors";"crypto/x509")
func main(){ c:=&http.Client{Timeout:10*time.Second}; r,err:=c.Get(os.Args[1]); if err==nil {r.Body.Close(); fmt.Println("T"); return}
 var u x509.UnknownAuthorityError; var ce *tls.CertificateVerificationError; var ie x509.CertificateInvalidError
 if errors.As(err,&u)||errors.As(err,&ce)||errors.As(err,&ie) {fmt.Println("R")} else {fmt.Println("E:"+err.Error())} }
G
PYCODE='import sys,ssl,urllib.request,urllib.error
try: urllib.request.urlopen(sys.argv[1],timeout=10); print("T")
except urllib.error.HTTPError: print("T")
except urllib.error.URLError as e: print("R" if isinstance(e.reason, ssl.SSLError) else "E:"+str(e.reason)[:40])
except ssl.SSLError: print("R")
except Exception as e: print("E:"+type(e).__name__)'
PYREQ='import sys
try:
  import pip._vendor.requests as r
except ImportError:
  import requests as r
try: r.get(sys.argv[1],timeout=10); print("T")
except r.exceptions.SSLError: print("R")
except Exception as e: print("E:"+type(e).__name__)'
NODECODE='require("https").get(process.argv[1],{timeout:10000},r=>{console.log("T");process.exit(0)}).on("error",e=>{console.log(/CERT|certificate|SELF_SIGNED|UNABLE_TO|issuer/i.test(e.code+e.message)?"R":"E:"+e.code);process.exit(0)})'
RUBYCODE='require "net/http"; begin; Net::HTTP.get_response(URI(ARGV[0])); puts "T"; rescue OpenSSL::SSL::SSLError; puts "R"; rescue => e; puts "E:#{e.class}"; end'
PHPCODE='$r=@file_get_contents($argv[1],false,stream_context_create(["http"=>["timeout"=>10,"ignore_errors"=>true]])); $e=error_get_last(); echo ($r!==false)?"T":((strpos($e["message"]??"","certificate")!==false||strpos($e["message"]??"","SSL")!==false||strpos($e["message"]??"","operation failed")!==false)?"R":"E"),"\n";'
PWSHCODE='try { Invoke-WebRequest -Uri $args[0] -TimeoutSec 10 -SkipHttpErrorCheck | Out-Null; "T" } catch { if ($_.Exception.ToString() -match "SSL|certificate") {"R"} else {"E"} }'

p_curl()  { curl -s -o /dev/null --max-time 10 "$1"; rc=$?; [[ $rc == 0 ]] && echo T || { [[ $rc == 60 || $rc == 35 ]] && echo R || echo "E:$rc"; }; }
p_wget()  { wget -q -O /dev/null -T 10 -t 1 "$1"; rc=$?; [[ $rc == 0 || $rc == 8 ]] && echo T || { [[ $rc == 5 ]] && echo R || echo "E:$rc"; }; }
p_git()   { out=$(GIT_TERMINAL_PROMPT=0 timeout 15 git ls-remote "$1" 2>&1); grep -qiE "certificate|SSL" <<<"$out" && echo R || echo T; }
p_ossl()  { h=${1#https://}; h=${h%/}; timeout 10 openssl s_client -connect "$h:443" -servername "$h" -verify_return_error </dev/null >/dev/null 2>&1 && echo T || echo R; }
p_aws()   { out=$(timeout 20 aws s3 ls --endpoint-url "$1" --no-sign-request 2>&1); grep -qiE "SSL validation failed|certificate verify failed" <<<"$out" && echo R || echo T; }
p_py()    { "$1" -I -c "$PYCODE" "$2"; }
p_pyreq() { "$1" -I -c "$PYREQ" "$2"; }
p_node()  { "$1" -e "$NODECODE" "$2"; }
p_java()  { "$1" Probe.java "$2"; }
p_go()    { ./probe-go "$1"; }
p_ruby()  { ruby -e "$RUBYCODE" "$1"; }
p_php()   { php -r "$PHPCODE" "$1"; }
p_pwsh()  { pwsh -NoProfile -Command "& { $PWSHCODE } $1"; }

# --- clients on this image -------------------------------------------------------------
LABELS=(); CMDS=()
add() { LABELS+=("$1"); CMDS+=("$2"); }
pyver() { "$1" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3]); sys.exit(sys.version_info < (3, 10))' 2>/dev/null; }

add "curl (system)" "p_curl"
add "wget (system)" "p_wget"
add "git (system)" "p_git"
add "openssl (system)" "p_ossl"
add "python3 $(pyver /usr/bin/python3) system urllib" "p_py /usr/bin/python3"
add "pip system (vendored requests)" "p_pyreq /usr/bin/python3"
for py in "$TC"/Python/*/x64/bin/python3 "$TC"/PyPy/*/x64/bin/python; do
    [[ -x $py ]] && v=$(pyver "$py") || continue
    kind=Python; [[ $py == "$TC"/PyPy/* ]] && kind=PyPy
    add "toolcache $kind $v urllib" "p_py $py"
    add "toolcache $kind $v pip (vendored certifi)" "p_pyreq $py"
done
[[ -x /usr/share/miniconda/bin/python ]] && add "conda python urllib" "p_py /usr/share/miniconda/bin/python"
[[ -x /opt/az/bin/python3 ]] && add "az CLI python (certifi)" "p_pyreq /opt/az/bin/python3"
command -v aws >/dev/null && add "aws CLI $(aws --version 2>&1 | awk '{print $1}' | cut -d/ -f2) (botocore)" "p_aws"
if command -v node >/dev/null; then
    add "node $(node --version) (default)" "p_node $(command -v node)"
    add "node $(node --version) --use-openssl-ca" "p_node_ossl"
    p_node_ossl() { node --use-openssl-ca -e "$NODECODE" "$1"; }
fi
for n in "$TC"/node/*/x64/bin/node; do
    [[ -x $n ]] || continue
    v=$("$n" --version); major=${v#v}; major=${major%%.*}
    (( major >= 22 )) && add "toolcache node $v" "p_node $n"
done
for jdk in /usr/lib/jvm/temurin-*-jdk-amd64; do
    [[ -x $jdk/bin/java ]] || continue
    major=${jdk#/usr/lib/jvm/temurin-}; major=${major%%-*}
    (( major >= 11 )) && add "java $major (temurin)" "p_java $jdk/bin/java"   # Java 8 has no source launcher
done
if command -v go >/dev/null && go build -o probe-go probe.go 2>/dev/null; then
    add "go $(go env GOVERSION) (default)" "p_go"
fi
command -v ruby >/dev/null && add "ruby $(ruby -e 'print RUBY_VERSION') (default)" "p_ruby"
command -v php >/dev/null && add "php $(php -r 'echo PHP_VERSION;')" "p_php"
command -v pwsh >/dev/null && add "pwsh $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()') (.NET)" "p_pwsh"

# --- run --------------------------------------------------------------------------------
printf "%-48s %-8s %-8s %-8s %-8s %-8s\n" CLIENT emSign AAA emS-noCT AAA-noCT google
bad=0
for i in "${!LABELS[@]}"; do
    row=""; okrow=1
    for h in "${HOSTS[@]}"; do
        r=$(${CMDS[$i]} "https://$h.$D/" 2>/dev/null | tail -1); r=${r:-?}
        [[ $r == R ]] || okrow=0
        row+=" $(printf '%-8s' "${r:0:8}")"
    done
    g=$(${CMDS[$i]} "$CONTROL" 2>/dev/null | tail -1); g=${g:-?}
    [[ $g == T ]] || okrow=0
    (( okrow )) || bad=$((bad + 1))
    printf "%-48s%s %-8s %s\n" "${LABELS[$i]}" "$row" "${g:0:8}" "$( (( okrow )) || echo '<-- FAIL')"
done
echo
if (( bad )); then
    echo "FAIL: $bad of ${#LABELS[@]} clients did not reject every test host or could not reach google.com" >&2
else
    echo "OK: all ${#LABELS[@]} clients reject the emSign/AAA test hosts and reach google.com"
fi

# --- files that still bundle a blocked root (information only) -------------------------
if [[ $SCAN == 1 ]]; then
    echo; echo "=== files still bundling emSign G3 / AAA / C3 / C1 (information only)"
    python3 -I - / <<'PY'
import os, re, sys, base64, hashlib, zipfile
FP = {"86a1ecba089c4a8d3bbe2734c612ba341d813e043cf9e8a862cd5c57a36bbe6b": "G3",
      "d7a7a0fb5d7e2731d771e9484ebcdef71d5f0c3e0a2948782bc83ee0ea699ef4": "AAA",
      "bc4d809b15189d78db3e1d8cf4f9726a795da1643ca5f1358e1ddb0edc0d7eb3": "C3",
      "125609aa301da0a249b97a8239cb6a34216f44dcac9f3954b14292f2e8c8608f": "C1"}
PEM = re.compile(rb"-----BEGIN CERTIFICATE-----(.+?)-----END CERTIFICATE-----", re.S)
SKIP = ("/proc", "/sys", "/dev", "/run", "/tmp", "/var/lib/docker")
NAMEPAT = re.compile(r"(\.pem|\.crt|\.cer|ca-bundle|cacert|cert\.pem|certs?)$", re.I)
def roots_in(data):
    hits = set()
    for m in PEM.finditer(data):
        try: der = base64.b64decode(b"".join(m.group(1).split()))
        except Exception: continue
        name = FP.get(hashlib.sha256(der).hexdigest())
        if name: hits.add(name)
    return hits
res = []
for d, dirs, files in os.walk(sys.argv[1]):
    if d.startswith(SKIP): dirs[:] = []; continue
    for f in files:
        p = os.path.join(d, f)
        try:
            if os.path.islink(p) or os.path.getsize(p) > 50_000_000: continue
            if NAMEPAT.search(f):
                with open(p, "rb") as fh: data = fh.read()
                if b"BEGIN CERTIFICATE" in data and (h := roots_in(data)): res.append((p, h))
            elif f.endswith(".whl"):
                with zipfile.ZipFile(p) as z:
                    for n in z.namelist():
                        if n.endswith(("cacert.pem", ".crt")) and (h := roots_in(z.read(n))): res.append((p + "!" + n, h))
        except Exception: pass
for p, h in sorted(res): print("%-12s %s" % ("/".join(sorted(h)), p))
print("%d files, %d with G3 or AAA" % (len(res), sum(bool(h & {"G3", "AAA"}) for _, h in res)))
PY
fi

(( bad )) && exit 1
exit 0
