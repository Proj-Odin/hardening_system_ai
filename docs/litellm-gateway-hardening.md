# LiteLLM Gateway Hardening

This guide describes the dedicated Debian/Ubuntu VM deployment created by:

- `scripts/setup-litellm-gateway.sh`
- `scripts/update-litellm-gateway.sh`
- `scripts/verify-litellm-gateway.sh`
- `scripts/backup-litellm-gateway.sh`

The VM acts as a LAN/Tailscale-only AI gateway in front of OpenRouter first, with room for local Ollama or vLLM later.

## What This Installs

- Docker and the Docker Compose plugin
- `cosign` for image signature verification
- UFW rules for SSH and trusted-CIDR-only LiteLLM access
- DOCKER-USER chain rules to reduce Docker published-port bypass of UFW
- `/opt/litellm-gateway/docker-compose.yml`
- `/opt/litellm-gateway/config/config.yaml`
- `/opt/litellm-gateway/.env`
- A LiteLLM container and a private Postgres container
- Local backups under `/opt/litellm-gateway/backups`

Postgres is not published to the LAN. LiteLLM is bound to the configured `BIND_ADDR:LITELLM_PORT` and then restricted with UFW plus DOCKER-USER rules.

## Why Docker, Not PyPI

The March 2026 LiteLLM PyPI compromise affected malicious `litellm` versions `1.82.7` and `1.82.8`. Those releases reportedly harvested secrets and added persistence. This installer therefore never installs LiteLLM from PyPI and fails verification if host PyPI LiteLLM is detected.

LiteLLM's public docs state that GHCR Docker images are signed with cosign and show the pinned public key URL introduced at commit `0112e53046018d726492c814b3644b7d376029d0`:

```sh
cosign verify \
  --key https://raw.githubusercontent.com/BerriAI/litellm/0112e53046018d726492c814b3644b7d376029d0/cosign.pub \
  ghcr.io/berriai/litellm:<release-tag>
```

The setup and update scripts use the same key URL and verify before running the image. They then resolve the pulled image to a `sha256` digest and write the digest into Compose, so the VM does not later drift to a different mutable tag. They also reject LiteLLM image references outside these signed BerriAI GHCR repositories:

- `ghcr.io/berriai/litellm`
- `ghcr.io/berriai/litellm-non_root`
- `ghcr.io/berriai/litellm-database`

Sources:

- LiteLLM Docker signature docs: https://berriai.github.io/litellm/#verify-docker-image-signatures
- Sigstore cosign install docs: https://docs.sigstore.dev/cosign/system_config/installation/
- PyPI incident reference: https://securitylabs.datadoghq.com/articles/litellm-compromised-pypi-teampcp-supply-chain-campaign/

This does not make supply-chain risk impossible. It reduces blast radius by avoiding host PyPI install paths, requiring signatures by default, pinning digests, limiting network exposure, and keeping provider keys scoped.

## Image Choice

Default:

```sh
ghcr.io/berriai/litellm-non_root:v1.83.0-stable
```

The non-root image is preferred. If LiteLLM key management or database migrations require a database-specific image in your chosen release, set `LITELLM_IMAGE` explicitly to a stable GHCR image and let the installer verify the same cosign signature before digest pinning.

LiteLLM's virtual key support requires Postgres plus `master_key` and `database_url` in `general_settings`. Some LiteLLM docs historically refer to a database-specific Dockerfile for proxy key management. This installer starts with the signed non-root image and Postgres; if `/key/generate` or migrations fail for a specific release, switch to a matching stable `ghcr.io/berriai/litellm-database:<version>-stable` image and rerun setup/update. The cosign and digest rules still apply.

The scripts refuse image tags containing:

- `latest`
- `main-latest`
- `nightly`
- `dev`

The setup script also keeps `config.yaml` non-world-readable while adjusting its owner to the verified container image's runtime UID/GID. That keeps the bind-mounted config readable to non-root LiteLLM images without making it world-readable on the host.

## Install On A Clean VM

Use Debian 12/13 or Ubuntu 24.04.

```sh
sudo ./scripts/setup-litellm-gateway.sh
```

Useful explicit form:

```sh
sudo LITELLM_IMAGE='ghcr.io/berriai/litellm-non_root:v1.83.0-stable' \
  ./scripts/setup-litellm-gateway.sh \
  --trusted-cidr 172.16.172.0/24 \
  --bind-addr 0.0.0.0 \
  --port 4000
```

The installer prompts for `OPENROUTER_API_KEY` if it is missing. Use a dedicated low-budget OpenRouter key for this gateway, not a personal master key.

After setup:

```sh
sudo /opt/litellm-gateway/verify-litellm-gateway.sh
sudo docker compose -p litellm-gateway -f /opt/litellm-gateway/docker-compose.yml ps
sudo ufw status verbose
```

The verification script runs a tiny OpenRouter-routed chat completion by default. To avoid provider spend during a smoke check, run:

```sh
sudo SKIP_PROVIDER_TEST=1 /opt/litellm-gateway/verify-litellm-gateway.sh
```

## Update

Updates require an explicit image target.

```sh
sudo /opt/litellm-gateway/update-litellm-gateway.sh \
  --image ghcr.io/berriai/litellm-non_root:v1.83.0-stable
```

The update script:

1. Rejects unsafe tags.
2. Pulls the image.
3. Verifies the cosign signature.
4. Resolves the digest.
5. Backs up compose/config/env metadata.
6. Replaces only the LiteLLM image digest.
7. Starts Compose.
8. Runs verification.
9. Rolls back the compose file if verification fails.

## Backup

Local backup:

```sh
sudo /opt/litellm-gateway/backup-litellm-gateway.sh
```

Backup contents:

- `docker-compose.yml`
- `config/config.yaml`
- `.env` as `env.gpg` when `BACKUP_GPG_RECIPIENT` is set and `gpg` is available, otherwise `env.SENSITIVE`
- Postgres dump when the database container is reachable
- `SHA256SUMS.txt`
- `litellm-gateway-backup.tar.gz`

Optional no-mount SMB upload:

```sh
sudo SMB_SHARE='//truenas/litellm-backups' \
  SMB_CREDS='/root/.smbcredentials/litellm-backups' \
  SMB_REMOTE_DIR='litellm-gateway' \
  /opt/litellm-gateway/backup-litellm-gateway.sh
```

This uses `smbclient` directly and does not require CIFS/NFS mounts.

## Rotate OpenRouter Key

1. Create a new low-budget OpenRouter key.
2. Edit `/opt/litellm-gateway/.env` and replace `OPENROUTER_API_KEY`.
3. Keep permissions strict:

```sh
sudo chmod 600 /opt/litellm-gateway/.env
sudo docker compose -p litellm-gateway -f /opt/litellm-gateway/docker-compose.yml up -d
sudo /opt/litellm-gateway/verify-litellm-gateway.sh
```

4. Revoke the old OpenRouter key after verification.

## Rotate LiteLLM Master Key

The master key controls admin-level access to the proxy. Rotate carefully:

1. Back up first:

```sh
sudo /opt/litellm-gateway/backup-litellm-gateway.sh
```

2. Replace `LITELLM_MASTER_KEY` in `/opt/litellm-gateway/.env` with a new `sk-...` value.
3. Restart Compose.
4. Recreate or verify virtual keys as needed.
5. Update clients only if they use the master key directly. Normal clients should use virtual keys.

## Virtual Keys

Create separate virtual keys for each client so budgets and incident response are cleanly scoped.

Recommended budgets:

- Tiny test key: very low daily/monthly cap
- ZeroClaw key: cap sized for normal ZeroClaw workload
- OpenClaw key: separate cap and alias
- NemoClaw key: separate cap and alias if used

Example master-key calls:

```sh
export LITELLM_BASE='http://<llm-gateway-ip>:4000'
export LITELLM_MASTER_KEY='sk-...'

curl -sS -X POST "$LITELLM_BASE/key/generate" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key_alias":"zeroclaw","models":["openrouter-auto"],"max_budget":10,"budget_duration":"30d"}'

curl -sS -X POST "$LITELLM_BASE/key/generate" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key_alias":"openclaw","models":["openrouter-auto"],"max_budget":10,"budget_duration":"30d"}'

curl -sS -X POST "$LITELLM_BASE/key/generate" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key_alias":"nemoclaw","models":["openrouter-auto"],"max_budget":10,"budget_duration":"30d"}'

curl -sS -X POST "$LITELLM_BASE/key/generate" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"key_alias":"testing","models":["openrouter-auto"],"max_budget":1,"budget_duration":"7d"}'
```

Store returned virtual keys in each app's secret store, not in shell history.

## Point ZeroClaw/OpenClaw/NemoClaw At LiteLLM

Use the OpenAI-compatible endpoint:

```yaml
base_url: http://<llm-gateway-ip>:4000/v1
model: openrouter-auto
api_key: <the app-specific LiteLLM virtual key>
```

Do not give apps the LiteLLM master key unless you are intentionally doing admin work.

## Check Spend And Logs

Container logs:

```sh
sudo docker compose -p litellm-gateway -f /opt/litellm-gateway/docker-compose.yml logs -f litellm
```

Spend/key metadata can be inspected through LiteLLM admin endpoints with the master key. Keep these calls on the LAN/Tailscale side of the network.

Examples:

```sh
curl -sS "$LITELLM_BASE/key/info" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"

curl -sS "$LITELLM_BASE/spend/logs" \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

## Firewall Notes

Docker can bypass normal UFW for published ports. The setup script uses both:

1. UFW: allows SSH and allows the LiteLLM port only from `TRUSTED_CIDR`.
2. DOCKER-USER chain: returns trusted CIDR traffic to Docker and drops other forwarded traffic to the LiteLLM container port.

Docker applies DNAT before packets reach `DOCKER-USER`, so the helper protects the container port `4000`. UFW still protects the configured host-side `LITELLM_PORT`.

The DOCKER-USER helper is installed at:

```sh
/usr/local/sbin/litellm-gateway-docker-user-rules
```

and persisted with:

```sh
litellm-gateway-firewall.service
```

Review firewall state:

```sh
sudo ufw status verbose
sudo iptables -S DOCKER-USER
```

## Optional Egress Control

The setup script always creates:

```sh
/opt/litellm-gateway/egress-allowlist.txt
```

With `--strict-egress`, it also creates a router firewall plan. It does not install brittle domain-to-IP fail-closed host rules by default because provider domains can move across CDNs. Enforce strict egress at your router/firewall if you want a fail-closed model.

## Emergency Response For Bad PyPI LiteLLM

If LiteLLM PyPI versions `1.82.7` or `1.82.8` were ever installed or run on a host:

1. Treat the host as compromised.
2. Rotate all secrets visible to the host or containers, including provider API keys, LiteLLM keys, database passwords, SSH keys, CI tokens, and cloud credentials.
3. Rebuild the VM from clean media.
4. Restore only known-good config and database backups.
5. Check Python site-packages for `litellm_init.pth` and other incident indicators before trusting any artifact.

Upgrading the Python package alone is not enough if persistence or credential theft may have occurred.
