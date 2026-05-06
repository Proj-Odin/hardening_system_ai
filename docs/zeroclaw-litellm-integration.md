# ZeroClaw LiteLLM Integration

Use ZeroClaw as an OpenAI-compatible client of LiteLLM. LiteLLM should hold the provider/cloud credentials and issue a scoped virtual key to ZeroClaw.

## Endpoint

Base URL:

```text
http://<LITELLM_HOST_IP>:<LITELLM_PORT>/v1
```

API key:

```text
LiteLLM virtual CLIENT_KEY
```

Primary chat model:

```text
ollama-kimi-k26-cloud
```

Embedding model:

```text
embed-nomic
```

## Architecture

```text
ZeroClaw host
  -> LiteLLM Gateway
  -> host Ollama daemon bridge
  -> Ollama Cloud
```

Do not use:

- ZeroClaw native Ollama provider for Ollama Cloud routing
- direct `ollama.com` calls from ZeroClaw
- `LITELLM_MASTER_KEY` in ZeroClaw

## Create A Client Key

On the LiteLLM gateway:

```sh
sudo /opt/litellm-gateway/create-litellm-client-key.sh --alias zeroclaw
```

Use the generated response field named `key` as `LITELLM_CLIENT_KEY`. The returned `token_id` is not the API key. The helper prints key length/prefix only and stores the full response in a protected file on the gateway.

## Before Blaming The Software

Run this checklist first:

- Am I on the ZeroClaw host for client tests, not accidentally on the LiteLLM gateway?
- Am I the `zeroclaw` user when running ZeroClaw?
- Is Docker running on the LiteLLM gateway?
- Is the LiteLLM stack running?
- Is this shell using the virtual key, not `token_id`?
- Did I export `LITELLM_CLIENT_KEY` in this shell?
- Is `LITELLM_CLIENT_KEY` length non-zero?
- Is the key scoped to the model I am testing?
- Is the endpoint `http://<LITELLM_HOST_IP>:<LITELLM_PORT>/v1`?
- Did I restart LiteLLM after editing gateway config?
- Did the gateway snapshot happen while the service was actually running?

Check key presence without printing the key:

```sh
printf 'LITELLM_CLIENT_KEY length: %s\n' "${#LITELLM_CLIENT_KEY}"
case "$LITELLM_CLIENT_KEY" in sk-*) echo 'prefix: sk-...' ;; *) echo 'prefix: unexpected or missing' ;; esac
```

If the length is `0`, your `Authorization` header is empty.

## Identity Sanity

Linux users are intentionally different:

- `root` or admin manages the LiteLLM gateway.
- `zeroclaw` runs ZeroClaw.
- `ollama` runs the Ollama daemon on the gateway.
- LiteLLM runs inside a non-root container.

Useful checks:

```sh
whoami
id
hostname
```

On the LiteLLM gateway:

```sh
ps -eo user,pid,cmd | grep '[o]llama'
getent passwd ollama
```

If the daemon runs as `ollama`, signing in as your admin user does not authenticate the daemon. The service user's public key must be added to `https://ollama.com/settings/keys`.

Compare public key fingerprints, never private key contents:

```sh
ssh-keygen -lf ~/.ollama/id_ed25519.pub
sudo ssh-keygen -lf /usr/share/ollama/.ollama/id_ed25519.pub
```

Different fingerprints mean different Ollama identities. The CLI may work while local daemon cloud inference returns unauthorized.

## Ollama Auth Distinctions

`OLLAMA_API_KEY`, `ollama signin`, and service-user SSH identity are separate:

- `OLLAMA_API_KEY` is for programmatic Ollama Cloud API access.
- `ollama signin` may authenticate CLI cloud use for the current Linux user.
- LiteLLM through the local daemon depends on the daemon service user's identity.
- `/api/tags` success does not prove `/api/chat` inference is authorized.

When checking cloud access on the gateway:

```sh
ollama signin
ollama list
ollama run gpt-oss:120b-cloud
```

Direct Ollama Cloud API tests:

```sh
curl https://ollama.com/api/tags \
  -H "Authorization: Bearer $OLLAMA_API_KEY"

curl https://ollama.com/v1/chat/completions \
  -H "Authorization: Bearer $OLLAMA_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-oss:120b-cloud","messages":[{"role":"user","content":"hello"}]}'
```

Local daemon bridge test:

```sh
curl http://127.0.0.1:11434/api/chat \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-oss:120b-cloud","stream":false,"messages":[{"role":"user","content":"hello"}]}'
```

If catalog access works but direct inference returns `401`, check account, subscription/entitlement, model name, or endpoint. If CLI works but daemon inference returns `401`, add the `ollama` service user's public key to `https://ollama.com/settings/keys`.

## Generic Client Tests

Run from the ZeroClaw host, or any trusted client in `<TRUSTED_CLIENT_CIDR>`:

```sh
printf 'LITELLM_CLIENT_KEY length: %s\n' "${#LITELLM_CLIENT_KEY}"
curl -sS "http://<LITELLM_HOST_IP>:<LITELLM_PORT>/v1/models" \
  -H "Authorization: Bearer $LITELLM_CLIENT_KEY"
```

Chat test:

```sh
curl -sS "http://<LITELLM_HOST_IP>:<LITELLM_PORT>/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_CLIENT_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ollama-kimi-k26-cloud",
    "messages": [
      {"role": "user", "content": "Reply with only these words: zeroclaw to litellm ok"}
    ],
    "max_tokens": 100,
    "temperature": 0
  }'
```

Expected text:

```text
zeroclaw to litellm ok
```

## Optional Targeted Test

If you save `ZEROCLAW_HOST_IP` in `/opt/litellm-gateway/gateway.env`, use it only for targeted firewall or reachability checks. The general configuration should still rely on `<LITELLM_HOST_IP>`, `<LITELLM_PORT>`, and a scoped LiteLLM virtual key.

`gateway.env` is non-secret gateway network config. Helper scripts parse it as data and do not source it as shell code. The protected `.env` file remains the secret store for LiteLLM and database credentials.
