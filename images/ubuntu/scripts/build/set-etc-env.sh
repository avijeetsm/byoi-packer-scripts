#!/bin/bash -e
################################################################################
##  File:  set-etc-env.sh
##  Desc:  Prepends HOME=$HOME to the /etc/environment file.
##         Environment variables in /etc/environment are set on build execution
##         system. On execution machine, HOME is set to "" by default. This
##         values needs to be updated to /home/ubuntu.
################################################################################

echo "Printing current /etc/environment file"
cat /etc/environment
sed -i "1s|^|HOME=/home/ubuntu\n|" /etc/environment
echo "Printing updated /etc/environment file"
cat /etc/environment