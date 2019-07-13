#!/bin/bash
set -e

## Prepare environment
[ ! -d ~/deployments ] && mkdir -p ~/deployments
[ ! -d ~/deployments/vbox ] && mkdir -p ~/deployments/vbox

pushd ~/workspace
[ ! -d ~/workspace/bosh-deployment ] && git clone https://github.com/cloudfoundry/bosh-deployment.git
[ ! -d ~/workspace/safe-boshrelease ] && git clone https://github.com/cloudfoundry-community/safe-boshrelease.git
[ ! -d ~/workspace/concourse-bosh-deployment ] && git clone https://github.com/concourse/concourse-bosh-deployment.git
[ ! -d ~/workspace/minio-boshrelease ] && git clone https://github.com/minio/minio-boshrelease.git
popd

## Deploy Director
bosh create-env ~/workspace/bosh-deployment/bosh.yml \
  --non-interactive \
  --state ~/deployments/vbox/state.json \
  -o ~/workspace/bosh-deployment/virtualbox/cpi.yml \
  -o ~/workspace/bosh-deployment/virtualbox/outbound-network.yml \
  -o ~/workspace/bosh-deployment/bosh-lite.yml \
  -o ~/workspace/bosh-deployment/bosh-lite-runc.yml \
  -o ~/workspace/bosh-deployment/uaa.yml \
  -o ~/workspace/bosh-deployment/credhub.yml \
  -o ~/workspace/bosh-deployment/jumpbox-user.yml \
  --vars-store ~/deployments/vbox/bosh-creds.yml \
  --vars-file ~/workspace/bootstrap-vbox/bosh/params/bosh-params.yml

export BOSH_DEPLOYMENT=vbox
export BOSH_ENVIRONMENT=https://192.168.50.6:25555
export BOSH_CA_CERT="$(bosh int ~/deployments/vbox/bosh-creds.yml --path /director_ssl/ca)"
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=`bosh int ~/deployments/vbox/bosh-creds.yml --path /admin_password`

## Prepare bosh for Vault, Concourse, and Minio Deployments
bosh upload-stemcell --sha1 bfeacdd2ef178742b211c9ea7f154e58fb28639a \
  https://bosh.io/d/stemcells/bosh-warden-boshlite-ubuntu-xenial-go_agent?v=315.64

bosh update-cloud-config ~/workspace/bootstrap-vbox/cloud-config/vbox-cloud-config.yml \
  --non-interactive \

## Deploy Vault
bosh  deploy -d vault ~/workspace/safe-boshrelease/manifests/safe.yml \
  --non-interactive \
  -o ~/workspace/bootstrap-vbox/vault/patch/manifest-patch.yml \
  --vars-store ~/deployments/vbox/vault-creds.yml \
  --vars-file ~/workspace/bootstrap-vbox/vault/params/vault-params.yml

export VAULT_ADDR=https://10.244.16.2
export VAULT_SKIP_VERIFY=true

# Initialize Vault
if [[ $* == *--initial* ]]
then
  vault operator init -format="json" > ~/deployments/vbox/tokens.json

  token0=$(cat ~/deployments/vbox/tokens.json | jq '.unseal_keys_b64[0]')
  token1=$(cat ~/deployments/vbox/tokens.json | jq '.unseal_keys_b64[1]')
  token2=$(cat ~/deployments/vbox/tokens.json | jq '.unseal_keys_b64[2]')
  root_token=$(cat ~/deployments/vbox/tokens.json | jq -r '.root_token')

  # Unseal the vault
  curl \
    -X PUT -k \
    -d '{"key":'$token0'}' \
    https://10.244.16.2/v1/sys/unseal

  curl \
    -X PUT -k \
    -d '{"key":'$token1'}' \
    https://10.244.16.2/v1/sys/unseal

  curl \
    -X PUT -k \
    -d '{"key":'$token2'}' \
    https://10.244.16.2/v1/sys/unseal

  echo "Logging into Vault"
  vault login ${root_token}
  echo "Enabling concourse secrets engine"
  vault secrets enable -version=1 -path=concourse kv
  echo "Creating policy"
  vault policy write concourse ~/workspace/bootstrap-vbox/vault/policies/concourse-policy.hcl
  echo "Creating token for concourse"
  vault token create --policy concourse --period 24h > ~/deployments/vbox/concourse-token.json
fi

## Get token from tokens.json file to update concourse params before deploying
## TODO: Fix this ugly janky code
if [[ ! $(cat ~/workspace/bootstrap-vbox/concourse/params/concourse-params.yml | grep concourse_vault_token:) ]]; then
  concourse_token=$(cat ~/deployments/vbox/concourse-token.json | grep 'token ' | awk '{print $NF}')
  echo "\nconcourse_vault_token: ${concourse_token}" >> ~/workspace/bootstrap-vbox/concourse/params/concourse-params.yml
fi

## Deploy concourse
bosh deploy -d concourse ~/workspace/concourse-bosh-deployment/cluster/concourse.yml \
  --non-interactive \
  -l ~/workspace/concourse-bosh-deployment/versions.yml \
  -o ~/workspace/concourse-bosh-deployment/cluster/operations/static-web.yml \
  -o ~/workspace/concourse-bosh-deployment/cluster/operations/basic-auth.yml \
  -o ~/workspace/concourse-bosh-deployment/cluster/operations/vault.yml \
  -o ~/workspace/concourse-bosh-deployment/cluster/operations/vault-shared-path.yml \
  -o ~/workspace/concourse-bosh-deployment/cluster/operations/vault-tls-skip_verify.yml \
  -o ~/workspace/bootstrap-vbox/concourse/patch/manifest-patch.yml \
  --vars-store ~/deployments/vbox/concourse-creds.yml \
  --vars-file ~/workspace/bootstrap-vbox/concourse/params/concourse-params.yml

## Deploy Minio
bosh deploy -d minio ~/workspace/minio-boshrelease/manifests/manifest-fs-example.yml \
  --non-interactive \
  -o ~/workspace/bootstrap-vbox/minio/patch/manifest-patch.yml \
  --vars-store ~/deployments/vbox/minio-creds.yml \
  --vars-file ~/workspace/bootstrap-vbox/minio/params/minio-params.yml

echo "##############################################################################################################################"
echo "#                              Successfully deployed BOSH, Vault, Concourse, and Minio!                                      #"
echo "##############################################################################################################################"
echo "# Add the route to be able to communicate with Bosh & SSH                                                                    #"
echo "# - cmd: sudo route add -net 10.244.0.0/16 192.168.50.6 # Mac OS X                                                           #"
echo "# Alias your environment                                                                                                     #"
echo "# - cmd: bosh alias-env vbox -e 192.168.50.6 --ca-cert <(bosh int ~/deployments/vbox/bosh-creds.yml --path /director_ssl/ca) #"
echo "# - Vault     https://10.244.16.2                                                                                            #"
echo "# - Concourse http://10.244.16.3:8080                                                                                        #"
echo "# - Minio     http://10.244.16.4:9000                                                                                        #"
echo "##############################################################################################################################"