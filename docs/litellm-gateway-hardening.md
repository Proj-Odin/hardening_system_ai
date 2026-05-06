# LiteLLM Gateway Hardening

This runbook covers a Docker-only LiteLLM gateway that fronts trusted LAN or Tailscale clients and routes Ollama-compatible models through a host Ollama daemon. The working architecture is:

```text
OpenAI-compatible client
  -> LiteLLM Gateway on Debian/Ubuntu
  -> host Ollama daemon bridge
  -> Ollama Cloud models
```

Postgres is private to Docker. LiteLLM is exposed only on the configured `LITELLM_PORT`, and firewall rules must restrict that port to `TRUSTED_CLIENT_CIDR`.

## Files

- `scripts/setup-litellm-gateway.sh`
- `scripts/configure-ollama-cloud-bridge.sh`
- `scripts/verify-litellm-gateway.sh`
- `scripts/verify-ollama-cloud-bridge.sh`
- `scripts/create-litellm-client-key.sh`
- `scripts/update-litellm-gateway.sh`
- `scripts/backup-litellm-gateway.sh`
- `/opt/litellm-gateway/.env`: protected secrets
- `/opt/litellm-gateway/gateway.env`: non-secret deployment network settings
- `/opt/litellm-gateway/config/config.yaml`
- `/opt/litellm-gateway/docker-compose.yml`

## Network Variables

Do not bake lab addresses into scripts or docs. The setup and bridge scripts accept flags and prompt when values are missing.

Required or commonly saved values:

- `LITELLM_HOST_IP`: LAN/Tailscale IP clients use for LiteLLM.
- `LITELLM_PORT`: client-facing LiteLLM port. Default prompt value is `4000`.
- `TRUSTED_CLIENT_CIDR`: subnet or single-client `/32` allowed to reach LiteLLM.
- `OLLAMA_BRIDGE_API_BASE`: URL LiteLLM uses from inside the container to reach host Ollama.
- `DOCKER_LITELLM_SUBNET`: Docker subnet allowed to reach host Ollama.
- `OLLAMA_HOST_BIND`: Ollama service bind, default `0.0.0.0:11434`; firewall rules must keep it private.
- `ZEROCLAW_HOST_IP`: optional, only for targeted examples/tests.

Example-only `gateway.env` values:

```sh
LITELLM_HOST_IP=192.168.1.50
LITELLM_PORT=4000
TRUSTED_CLIENT_CIDR=192.168.1.0/24
OLLAMA_BRIDGE_API_BASE=http://172.30.0.1:11434
DOCKER_LITELLM_SUBNET=172.30.0.0/16
OLLAMA_HOST_BIND=0.0.0.0:11434
```

Use your detected Docker network gateway and subnet, not these example-only values.

## Supply-Chain Posture

The March 2026 LiteLLM PyPI compromise affected malicious `litellm` versions `1.82.7` and `1.82.8`. This gateway never installs LiteLLM from PyPI and verification fails if host PyPI LiteLLM is detected.

The default image is the known working post-incident signed image:

```sh
ghcr.io/berriai/litellm-non_root:v1.83.3-stable.patch.2
```

The earlier generated default `ghcr.io/berriai/litellm-non_root:v1.83.0-stable` failed to pull and should not be used.

Setup and update still:

- reject `latest`, `main-latest`, `nightly`, and `dev` tags
- allow only signed BerriAI GHCR LiteLLM repositories
- verify the LiteLLM image with `cosign` by default
- resolve the image to an immutable `sha256` digest
- write Docker Compose with the digest

## Runtime Corrections

The generated Compose file keeps the config bind mount read-only:

```yaml
volumes:
  - type: bind
    source: /opt/litellm-gateway/config/config.yaml
    target: /app/config.yaml
    read_only: true
```

The LiteLLM service filesystem is intentionally not fully read-only:

```yaml
read_only: false
mem_limit: 2g
```

LiteLLM/Prisma writes cache, migration, and sanity-check files during startup. A fully read-only service filesystem can leave the process started but with no port open and empty logs. The memory limit is `2g` because startup can approach the old `1g` budget.

Health checks use:

```text
/health/liveliness
```

Do not use unauthenticated `/health` as the primary readiness check. Some LiteLLM builds return `401 Unauthorized` for `/health` while `/health/liveliness` returns `200 OK`.

## Install

Interactive:

```sh
sudo ./scripts/setup-litellm-gateway.sh
```

Non-interactive example:

```sh
sudo ./scripts/setup-litellm-gateway.sh \
  --litellm-host-ip <LITELLM_HOST_IP> \
  --litellm-port <LITELLM_PORT> \
  --trusted-client-cidr <TRUSTED_CLIENT_CIDR> \
  --ollama-bridge-api-base <OLLAMA_BRIDGE_API_BASE> \
  --docker-litellm-subnet <DOCKER_LITELLM_SUBNET> \
  --yes
```

The setup script prompts for an optional `OPENROUTER_API_KEY`. Leave it blank unless you want the `openrouter-auto` route.

## Ollama Cloud Bridge

Configure the host Ollama daemon:

```sh
sudo /opt/litellm-gateway/configure-ollama-cloud-bridge.sh
```

Useful flags:

```sh
sudo /opt/litellm-gateway/configure-ollama-cloud-bridge.sh \
  --ollama-bridge-api-base <OLLAMA_BRIDGE_API_BASE> \
  --docker-litellm-subnet <DOCKER_LITELLM_SUBNET> \
  --yes
```

The script:

- checks whether `ollama` is installed
- installs Ollama only when `--install-ollama` is passed
- prints the Ollama version
- detects the `ollama` service account and service home
- prints the service public key path, normally `/usr/share/ollama/.ollama/id_ed25519.pub`
- tells you to add that public key at `https://ollama.com/settings/keys`
- does not copy an admin private key by default
- supports emergency `--copy-admin-key` with a warning
- writes `/etc/systemd/system/ollama.service.d/override.conf`
- restarts Ollama
- verifies port `11434` is listening
- detects or prompts for the Docker subnet
- adds a UFW rule allowing only `DOCKER_LITELLM_SUBNET` to reach port `11434`

The systemd override uses:

```ini
[Service]
Environment="OLLAMA_HOST=<OLLAMA_HOST_BIND>"
```

Keep `11434` private. The listener can bind broadly, but firewall rules must restrict it to trusted Docker or LAN intent.

## Models

Generated `config.yaml` uses the selected `OLLAMA_BRIDGE_API_BASE` for:

- `ollama-gpt-oss-cloud`
- `ollama-kimi-k26-cloud`
- `ollama-glm-51-cloud`
- `ollama-deepseek-v4-pro-cloud`
- `ollama-gemma4-31b-cloud`
- `ollama-nemotron-3-super-cloud`
- `embed-nomic`
- `embed-embeddinggemma`
- `embed-qwen3`

Chat cloud models are offloaded through Ollama Cloud. Embedding models are local Ollama models unless you explicitly configure a cloud embedding model.

Pull local embedding models before testing:

```sh
ollama pull nomic-embed-text
ollama pull embeddinggemma
ollama pull qwen3-embedding
```

`embed-nomic` and `embed-embeddinggemma` have been tested successfully through LiteLLM when the local models are present. `embed-qwen3` is configured but should be pulled and tested separately.

## Verification

LiteLLM checks:

```sh
sudo /opt/litellm-gateway/verify-litellm-gateway.sh
```

Bridge checks:

```sh
sudo /opt/litellm-gateway/verify-ollama-cloud-bridge.sh
```

The verification flow checks:

- Docker Compose health for LiteLLM and Postgres
- digest-pinned images
- `.env` and `gateway.env` permissions
- no host PyPI LiteLLM package
- unauthenticated `http://127.0.0.1:<LITELLM_PORT>/health/liveliness`
- authenticated `/v1/models`
- chat completion with `ollama-kimi-k26-cloud`, falling back to `ollama-gpt-oss-cloud`
- host Ollama `/api/tags`
- host access through `OLLAMA_BRIDGE_API_BASE`
- LiteLLM container access to host Ollama
- direct Ollama cloud chat
- LiteLLM chat through the Ollama bridge
- LiteLLM embeddings through local Ollama

## Client Virtual Keys

Do not put `LITELLM_MASTER_KEY` in clients. Create scoped virtual keys:

```sh
sudo /opt/litellm-gateway/create-litellm-client-key.sh --alias zeroclaw
```

By default the key includes:

- all configured Ollama cloud chat models
- `embed-nomic`
- `embed-embeddinggemma`
- `embed-qwen3`

It excludes `openrouter-auto` unless `--include-openrouter` is passed.

The response field named `key` is the client API key. `token_id` is not the API key. The helper stores the full response in a protected file and prints key length/prefix only.

## Before Blaming The Software

Run this checklist before debugging LiteLLM, Ollama, ZeroClaw, or firewall behavior:

- Am I on the right VM?
- Am I the right Linux user?
- Is Docker running?
- Is LiteLLM running?
- Is the client using the virtual key, not `token_id`?
- Did I source/export the key in this shell?
- Is the key length non-zero?
- Is the Ollama daemon service user authorized, not just my admin user?
- Did I add the service user's public key to `https://ollama.com/settings/keys`?
- Is the model local, cloud, or routed through LiteLLM?
- Am I using the correct endpoint?
- LiteLLM clients use `/v1`.
- Local Ollama daemon calls use `/api/chat`, `/api/generate`, or `/api/embed`.
- Direct Ollama Cloud OpenAI-compatible calls use `/v1`.
- Did I restart LiteLLM after editing `config.yaml`?
- Did I snapshot with the service actually running?

The scripts print an "Account and credential sanity checks" section to make these mistakes obvious early.

## Account And Credential Sanity Checks

Linux identities matter:

- `admin` or `root` installs packages and manages services.
- `zeroclaw` runs ZeroClaw.
- `ollama` runs the Ollama daemon.
- The LiteLLM container runs as a non-root user such as `nobody`.

Useful identity commands:

```sh
whoami
id
hostname
ps -eo user,pid,cmd | grep '[o]llama'
getent passwd ollama
```

If the Ollama daemon runs as `ollama`, signing in as your admin user does not automatically authenticate the daemon.

Compare current-user and service-user Ollama public key fingerprints:

```sh
ssh-keygen -lf ~/.ollama/id_ed25519.pub
sudo -u ollama ssh-keygen -lf /usr/share/ollama/.ollama/id_ed25519.pub
```

If they differ, they are different Ollama identities. The CLI may work while the local API daemon returns unauthorized for cloud models.

Never print or copy private key contents. Prefer adding the service user's public key to `https://ollama.com/settings/keys`.

## Ollama Auth Sanity

`OLLAMA_API_KEY`, `ollama signin`, and the service user's SSH identity are different things:

- `OLLAMA_API_KEY` is for programmatic cloud API access.
- Ollama CLI cloud use may rely on `ollama signin` and local SSH identity files.
- Local Ollama daemon cloud access uses the `ollama` service user's identity, not necessarily the admin user's `OLLAMA_API_KEY`.
- `/api/tags` success does not prove `/api/chat` or `/api/generate` inference is authorized.
- Model listing and inference may fail differently.

Manual checks:

```sh
ollama signin
ollama list
ollama run gpt-oss:120b-cloud
```

The verification script distinguishes these paths:

```sh
curl https://ollama.com/api/tags \
  -H "Authorization: Bearer $OLLAMA_API_KEY"

curl https://ollama.com/v1/chat/completions \
  -H "Authorization: Bearer $OLLAMA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-oss:120b-cloud","messages":[{"role":"user","content":"hello"}]}'

curl http://127.0.0.1:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-oss:120b-cloud","stream":false,"messages":[{"role":"user","content":"hello"}]}'

curl http://127.0.0.1:<LITELLM_PORT>/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"ollama-kimi-k26-cloud","messages":[{"role":"user","content":"hello"}]}'
```

If catalog access works but inference returns `401`, check account, subscription/entitlement, model name, and endpoint. If CLI works but local daemon inference returns `401`, add the service user's public key to `https://ollama.com/settings/keys`.

## Secret And Database Sanity

The scripts report secrets without printing full values:

```text
LITELLM_MASTER_KEY=SET length=N prefix=sk-...
DATABASE_URL=SET length=N prefix=postgresql://litellm:***@postgres:5432/litellm
POSTGRES_PASSWORD=SET length=N prefix=<set>
OLLAMA_API_KEY=MISSING
LITELLM_CLIENT_KEY=SET length=N prefix=sk-...
```

Required LiteLLM values:

- `LITELLM_MASTER_KEY`
- `LITELLM_SALT_KEY`
- `DATABASE_URL`
- `POSTGRES_PASSWORD`

Optional values:

- `OPENROUTER_API_KEY`
- `OLLAMA_API_KEY`
- `LITELLM_CLIENT_KEY` for client-key tests

If `POSTGRES_PASSWORD` and the password embedded in `DATABASE_URL` differ, LiteLLM may restart or fail database authentication. Repair it with:

```sh
sudo /opt/litellm-gateway/verify-litellm-gateway.sh --repair-database-url
```

This backs up `.env` and rewrites:

```text
DATABASE_URL=postgresql://litellm:${POSTGRES_PASSWORD}@postgres:5432/litellm
```

## Host And Service Sanity

Every gateway script prints:

```text
You are running this on: <hostname> (<OS>)
Detected role: <role>
Expected role for this script: <role>
```

LiteLLM setup is expected on the Debian/Ubuntu LiteLLM gateway. If setup appears to be running on Alpine or a ZeroClaw host, it requires `--force`.

Service checks:

```sh
systemctl is-enabled docker
systemctl is-active docker
docker compose -p litellm-gateway -f /opt/litellm-gateway/docker-compose.yml ps
```

If the stack is installed but not running:

```sh
sudo docker compose -p litellm-gateway -f /opt/litellm-gateway/docker-compose.yml up -d
```

If Docker is disabled or inactive:

```sh
sudo systemctl enable --now docker
```

Firewall/access checks:

```sh
ss -lntp | grep 4000
sudo ufw status verbose
curl http://<LITELLM_HOST_IP>:<LITELLM_PORT>/v1/models \
  -H "Authorization: Bearer $LITELLM_CLIENT_KEY"
```

If ping fails but curl works, ICMP may be blocked. If curl fails and the client should be trusted, check the LiteLLM stack, UFW allow rule for `<TRUSTED_CLIENT_CIDR>` to `<LITELLM_PORT>`, Proxmox firewall, wrong IP, and Docker port binding.

## Startup After Snapshot Or Reboot

Enable Docker:

```sh
sudo systemctl enable docker
```

Start the stack:

```sh
sudo docker compose -p litellm-gateway -f /opt/litellm-gateway/docker-compose.yml up -d
```

Check it:

```sh
sudo docker compose -p litellm-gateway -f /opt/litellm-gateway/docker-compose.yml ps
```

Compose services use `restart: unless-stopped`, but after snapshots or host maintenance still confirm the stack is actually running.

## Acceptance Criteria

After setup and bridge configuration:

- `docker compose ps` shows LiteLLM healthy
- `docker compose ps` shows Postgres healthy
- `/health/liveliness` returns `200`
- `/v1/models` with the master key returns all configured models
- `/v1/models` with a scoped client key excludes `openrouter-auto` unless explicitly included
- LiteLLM chat with `ollama-kimi-k26-cloud` returns the expected text
- LiteLLM embeddings with `embed-nomic` return an embedding vector
- LiteLLM embeddings with `embed-embeddinggemma` return an embedding vector if the model is pulled
- trusted clients can reach `/v1/models` using a virtual client key
- trusted clients can reach `/v1/chat/completions` using a virtual client key

## Known Failure Symptoms

- Empty Docker logs plus no port `4000`: likely a fully read-only LiteLLM filesystem.
- LiteLLM health stuck: check `/health` versus `/health/liveliness`.
- Ollama CLI works but local API returns unauthorized: the daemon runs as the `ollama` user and its service public key must be added at `https://ollama.com/settings/keys`.
- Container cannot reach host Ollama: check `OLLAMA_HOST=<OLLAMA_HOST_BIND>` and the UFW rule for `<DOCKER_LITELLM_SUBNET>`.
- Client cannot reach LiteLLM: make sure the stack is running and UFW allows `<TRUSTED_CLIENT_CIDR>` to `<LITELLM_PORT>/tcp`.
- `/v1/models` works but chat returns empty content: increase `max_tokens`; reasoning models may consume tiny token budgets.

## Security Posture

- Do not expose LiteLLM to the public internet.
- Allow only LAN/Tailscale clients.
- Do not expose Ollama port `11434` publicly.
- Use LiteLLM virtual keys for clients.
- Do not use `LITELLM_MASTER_KEY` in client apps.
- Keep provider and cloud keys out of client configs.
- Keep `/opt/litellm-gateway/.env` mode `600`.
- Keep `config.yaml` mounted read-only.
- Keep image digest pinning and cosign verification enabled.
