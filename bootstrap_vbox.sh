#!/bin/bash
set -e
INITIAL=False
TLS=False

if [[ $* == *--initial* ]]; then
    INITIAL=True
fi

if [[ $* == *--tls* ]]; then
    TLS=True
fi

SCRIPTPATH=$(dirname $(cd "$(dirname "${BASH_SOURCE[0]}")"; pwd -P)/$(basename "${BASH_SOURCE[0]}"))
WORKSPACE=$(dirname ${SCRIPTPATH})
PARENTPATH=$(dirname ${WORKSPACE})
DEPLOYMENTS=${PARENTPATH}/deployments/vbox

STEMCELLNAME=bosh-warden-boshlite-ubuntu-xenial-go_agent
STEMCELLVERSION=315.64
STEMCELLSHA1=bfeacdd2ef178742b211c9ea7f154e58fb28639a

## Prepare environment
[ ! -d ${DEPLOYMENTS} ] && mkdir -p ${DEPLOYMENTS}

pushd ${WORKSPACE}
[ ! -d ${WORKSPACE}/bosh-deployment ] && git clone https://github.com/cloudfoundry/bosh-deployment.git
[ ! -d ${WORKSPACE}/safe-boshrelease ] && git clone https://github.com/cloudfoundry-community/safe-boshrelease.git
[ ! -d ${WORKSPACE}/concourse-bosh-deployment ] && git clone https://github.com/concourse/concourse-bosh-deployment.git
[ ! -d ${WORKSPACE}/minio-boshrelease ] && git clone https://github.com/minio/minio-boshrelease.git
popd

## Deploy Director
bosh create-env ${WORKSPACE}/bosh-deployment/bosh.yml \
  --non-interactive \
  --state ${DEPLOYMENTS}/state.json \
  -o ${WORKSPACE}/bosh-deployment/virtualbox/cpi.yml \
  -o ${WORKSPACE}/bosh-deployment/virtualbox/outbound-network.yml \
  -o ${WORKSPACE}/bosh-deployment/bosh-lite.yml \
  -o ${WORKSPACE}/bosh-deployment/bosh-lite-runc.yml \
  -o ${WORKSPACE}/bosh-deployment/uaa.yml \
  -o ${WORKSPACE}/bosh-deployment/credhub.yml \
  -o ${WORKSPACE}/bosh-deployment/jumpbox-user.yml \
  -o ${WORKSPACE}/bootstrap-vbox/bosh/patch/manifest-patch.yml \
  --vars-store ${DEPLOYMENTS}/bosh-creds.yml \
  --vars-file ${WORKSPACE}/bootstrap-vbox/bosh/params/bosh-params.yml

export BOSH_DEPLOYMENT=vbox
export BOSH_ENVIRONMENT=https://192.168.50.6:25555
export BOSH_CA_CERT="$(bosh int ${DEPLOYMENTS}/bosh-creds.yml --path /director_ssl/ca)"
export BOSH_CLIENT=admin
export BOSH_CLIENT_SECRET=`bosh int ${DEPLOYMENTS}/bosh-creds.yml --path /admin_password`

if [[ "${INITIAL}" == 'False' ]]; then
  ## Prepare bosh for Vault, Concourse, and Minio Deployments
  FOUNDSTEMCELLNAME=$(bosh stemcells --column Name | tr -d ' ')
  FOUNDSTEMCELLVERSION=$(bosh stemcells --column Version | tr -d ' ' | grep -oe [0-9.]*)
  if [[ "${FOUNDSTEMCELLNAME}" -eq "${STEMCELLNAME}" ]]; then
      if [[ "${FOUNDSTEMCELLVERSION}" == "${STEMCELLVERSION}" ]]; then
          echo -e "\nStemcell '${STEMCELLNAME} ${STEMCELLVERSION}' already exists.\n"
      else
          bosh upload-stemcell --sha1 ${STEMCELLSHA1} \
              https://bosh.io/d/stemcells/${STEMCELLNAME}?v=${STEMCELLVERSION}
      fi
  else
      bosh upload-stemcell --sha1 ${STEMCELLSHA1} \
          https://bosh.io/d/stemcells/${STEMCELLNAME}?v=${STEMCELLVERSION}
  fi
else
    bosh upload-stemcell --sha1 ${STEMCELLSHA1} \
        https://bosh.io/d/stemcells/${STEMCELLNAME}?v=${STEMCELLVERSION}
fi

bosh update-cloud-config ${WORKSPACE}/bootstrap-vbox/cloud-config/vbox-cloud-config.yml \
  --non-interactive \

if [[ "${TLS}" == 'True' ]]; then
    echo -e "\nPatch Vault TLS\n"
    ## Patch Vault manifest yaml for tls certs
    VAULTPATCH=${WORKSPACE}/bootstrap-vbox/vault/patch/manifest-patch-tls.yml
else
    VAULTPATCH=${WORKSPACE}/bootstrap-vbox/vault/patch/manifest-patch.yml
fi

## Deploy Vault
bosh  deploy -d vault ${WORKSPACE}/bootstrap-vbox/vault/safe.yml \
  --non-interactive \
  -o ${VAULTPATCH} \
  --vars-store ${DEPLOYMENTS}/vault-creds.yml \
  --vars-file ${WORKSPACE}/bootstrap-vbox/vault/params/vault-params.yml

export VAULT_ADDR=https://10.244.16.2
export VAULT_SKIP_VERIFY=true

# Initialize Vault
if [[ "${INITIAL}" == 'True' ]]
then
  vault operator init -format="json" > ${DEPLOYMENTS}/tokens.json

  token0=$(cat ${DEPLOYMENTS}/tokens.json | jq '.unseal_keys_b64[0]')
  token1=$(cat ${DEPLOYMENTS}/tokens.json | jq '.unseal_keys_b64[1]')
  token2=$(cat ${DEPLOYMENTS}/tokens.json | jq '.unseal_keys_b64[2]')
  root_token=$(cat ${DEPLOYMENTS}/tokens.json | jq -r '.root_token')

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
  vault policy write concourse ${WORKSPACE}/bootstrap-vbox/vault/policies/concourse-policy.hcl
  echo "Creating token for concourse"
  vault token create --policy concourse --period 24h > ${DEPLOYMENTS}/concourse-token.json
fi

## Get token from tokens.json file to update concourse params before deploying
## TODO: Fix this ugly janky code
if [[ ! $(cat ${WORKSPACE}/bootstrap-vbox/concourse/params/concourse-params.yml | grep concourse_vault_token:) ]]; then
  concourse_token=$(cat ${DEPLOYMENTS}/concourse-token.json | grep 'token ' | awk '{print $NF}')
  echo -e "\nconcourse_vault_token: ${concourse_token}" >> ${WORKSPACE}/bootstrap-vbox/concourse/params/concourse-params.yml
fi

if [[ "${TLS}" == 'True' ]]; then
    echo -e "\nPatch Concourse TLS\n"
    ## Patch concourse manifest yaml for tls certs
    CONCOURSEPATCH=${WORKSPACE}/bootstrap-vbox/concourse/patch/manifest-patch-tls.yml
else
    CONCOURSEPATCH=${WORKSPACE}/bootstrap-vbox/concourse/patch/manifest-patch.yml
fi

## Deploy concourse
bosh deploy -d concourse ${WORKSPACE}/concourse-bosh-deployment/cluster/concourse.yml \
  --non-interactive \
  -l ${WORKSPACE}/concourse-bosh-deployment/versions.yml \
  -o ${WORKSPACE}/concourse-bosh-deployment/cluster/operations/static-web.yml \
  -o ${WORKSPACE}/concourse-bosh-deployment/cluster/operations/basic-auth.yml \
  -o ${WORKSPACE}/concourse-bosh-deployment/cluster/operations/vault.yml \
  -o ${WORKSPACE}/concourse-bosh-deployment/cluster/operations/vault-shared-path.yml \
  -o ${WORKSPACE}/concourse-bosh-deployment/cluster/operations/vault-tls-skip_verify.yml \
  -o ${CONCOURSEPATCH} \
  --vars-store ${DEPLOYMENTS}/concourse-creds.yml \
  --vars-file ${WORKSPACE}/bootstrap-vbox/concourse/params/concourse-params.yml

if [[ "${TLS}" == 'True' ]]; then
    echo -e "\nPatch Minio TLS\n"
    ## Patch concourse manifest yaml for tls certs
    MINIOPATCH=${WORKSPACE}/bootstrap-vbox/minio/patch/manifest-patch-tls.yml
else
    MINIOPATCH=${WORKSPACE}/bootstrap-vbox/minio/patch/manifest-patch.yml
fi

## Deploy Minio
bosh deploy -d minio ${WORKSPACE}/minio-boshrelease/manifests/manifest-fs-example.yml \
  --non-interactive \
  -o ${MINIOPATCH} \
  --vars-store ${DEPLOYMENTS}/minio-creds.yml \
  --vars-file ${WORKSPACE}/bootstrap-vbox/minio/params/minio-params.yml

echo "##############################################################################################################################"
echo "#                              Successfully deployed BOSH, Vault, Concourse, and Minio!                                      #"
echo "##############################################################################################################################"
echo "# Add the route to be able to communicate with Bosh & SSH                                                                    #"
echo "# Alias your environment                                                                                                     #"
echo "# - cmd: bosh alias-env vbox -e 192.168.50.6 --ca-cert <(bosh int ${DEPLOYMENTS}/bosh-creds.yml --path /director_ssl/ca)     #"
echo "# - Vault     https://10.244.16.2                                                                                            #"
echo "# - Concourse http://10.244.16.3:8080                                                                                        #"
echo "# - Minio     http://10.244.16.4:9000                                                                                        #"
echo "##############################################################################################################################"
