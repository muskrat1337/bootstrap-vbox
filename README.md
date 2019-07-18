# bootstrap-vbox

Requires Virtualbox, which can be downloaded from here: https://www.virtualbox.org/

## Tools

- Vault CLI: https://www.vaultproject.io/downloads.html
- Minio CLI: brew install minio/stable/mc
- BOSH CLI:  brew install cloudfoundry/tap/bosh-cli
- jq:        brew install jq

## Initial setup

```bash
mkdir workspace
cd ~/workspace
git clone https://github.com/jmcclenny-epoc/bootstrap-vbox.git
sudo route add -net 10.244.0.0/16 192.168.50.6 # Mac OS X
```

- First run `./bootstrap_vbox.sh --initial`
- Subsequent `./bootstrap_vbox.sh`

## Alias your environment

```bash
bosh alias-env vbox -e 192.168.50.6 --ca-cert <(bosh int ~/deployments/vbox/bosh-creds.yml --path /director_ssl/ca)
```

## URL's

```bash
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

## Known Issues

- Time for some reason doesn't sync on minio server, need to run the `fix_minio_time.sh` script in order to use the Minio Client CLI.

- The route doesn't survive a reboot. Researching if it is even worth persisting.

- Sometimes concourse deployment fails, just re-run the script without `--initial` flag.
