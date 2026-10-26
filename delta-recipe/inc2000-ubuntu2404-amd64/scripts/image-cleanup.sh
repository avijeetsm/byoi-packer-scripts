#!/usr/bin/env bash
################################################################################
##  File:  image-cleanup.sh
##  Desc:  Remove what the INC-2000 fix scripts leave behind before the image is captured.
##         The backups hold the old pip wheels and CodeQL cacerts, which still contain the
##         blocked roots, so they must not ship in the image.
##         /etc/ca-certificates.conf.inc2000.bak is kept: it holds no certificates.
################################################################################
set -uo pipefail

TC=/opt/hostedtoolcache

rm -rf /var/backups/inc2000
find "$TC/CodeQL" -name 'cacerts.inc2000.orig' -delete 2>/dev/null
# download caches from the pip / npm / gem runs as root
rm -rf /root/.cache/pip /root/.npm /root/.local/share/gem /root/.gem

left=$( { ls -d /var/backups/inc2000 2>/dev/null; find "$TC/CodeQL" -name 'cacerts.inc2000.orig' 2>/dev/null; } | wc -l)
[[ $left == 0 ]] && echo "OK: INC-2000 backups removed" || { echo "FAIL: $left INC-2000 backup(s) still present" >&2; exit 1; }
