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

Use the returned `key` value as `LITELLM_CLIENT_KEY`. The returned `token_id` is not the API key.

## Generic Client Tests

Run from the ZeroClaw host, or any trusted client in `<TRUSTED_CLIENT_CIDR>`:

```sh
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

