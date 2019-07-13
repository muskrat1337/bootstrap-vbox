# bootstrap-vbox

Requires Virtualbox, which can be downloaded from here: https://www.virtualbox.org/

## Tools

- Vault CLI: https://www.vaultproject.io/downloads.html
- Minio CLI: brew install minio/stable/mc
- BOSH CLI:  brew install cloudfoundry/tap/bosh-cli

## Initial setup

```bash
mkdir workspace
cd ~/workspace
git clone https://github.com/jmcclenny-epoc/bootstrap-vbox.git
```

- First run `./bootstrap_vbox.sh --initial`
- Subsequent `./bootstrap_vbox.sh`

## Add the route to be able to BOSH SSH

```bash
sudo route add -net 10.244.0.0/16 192.168.50.6 # Mac OS X
```

## Alias your environment

```bash
bosh alias-env vbox -e 192.168.50.6 --ca-cert <(bosh int ~/deployments/vbox/bosh-creds.yml --path /director_ssl/ca)
Vault     https://10.244.16.2
Concourse http://10.244.16.3:8080
Minio     http://10.244.16.4:9000
```

## Writing credentials to vault

```bash
export VAULT_ADDR=https://10.244.16.2
export VAULT_SKIP_VERIFY=true
root_token=$(cat ~/deployments/vbox/tokens.json | jq -r '.root_token')

vault write concourse/common/<key_name> value="<value>"
vault write concourse/<team_name>/<key_name> value"<value>"
vault write concourse/<team_name>/<pipeline_name>/<key_name> value"<value>"
```
