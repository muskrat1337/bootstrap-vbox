#!/bin/bash

set -e

# Time sync fix
export BOSH_DEPLOYMENT=vbox
export BOSH_ENVIRONMENT=https://192.168.50.6:25555
export BOSH_CA_CERT="$(bosh int ~/deployments/vbox/bosh-creds.yml --path /director_ssl/ca)"
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=`bosh int ~/deployments/vbox/bosh-creds.yml --path /admin_password`

date=$(date -u "+%H:%M:%S")
bosh ssh -d minio -c "sudo date +%T -s ${date}"