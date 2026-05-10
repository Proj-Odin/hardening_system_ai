# ZeroClaw Safe Embeddings

This runbook is for the Alpine LXC ZeroClaw source-build path managed by this repo. It adds deployment guardrails for using ZeroClaw SQLite memory with LiteLLM text embeddings.

## Architecture

```text
ZeroClaw
  -> LiteLLM
  -> local Ollama
  -> embed-nomic for text embeddings
```

Known working text embedding route:

```toml
[memory]
backend = "sqlite"
auto_save = true
embedding_provider = "litellm"
embedding_model = "embed-nomic"
embedding_dimensions = 768
embed_media_placeholders = false
embed_assistant_image_summaries = true
skip_embedding_for_image_messages = true
embedding_text_max_chars = 8192
```

Backup route:

```toml
[memory]
embedding_provider = "litellm"
embedding_model = "embed-embeddinggemma"
embedding_dimensions = "<set to the tested deployed dimension>"
```

## Rule

Embedders are text-only. Images should go to a vision model first. Only captions, summaries, OCR, transcripts, and other plain text should be embedded.

Never send these to `/v1/embeddings`:

- raw image bytes
- base64 image data
- `image_url` fields
- Telegram file blobs or raw file IDs
- provider multimodal payload objects
- provider-specific image markers such as `[IMAGE:...]`

## Safe Workflow

Text-only:

- save and embed the text

Image-only:

- send the image to the vision model
- skip embedding unless a text caption or summary exists

Text + image:

- send the original text+image payload to the provider
- send a cloned sanitized text-only copy to memory
- send only that text copy to the embedder

After a vision response, it is safe to save/embed the assistant's plain-text description, for example: `Assistant identified cable labeling issue in server rack.`

## Configure

Disable embeddings while preserving SQLite memory:

```sh
sudo ./scripts/configure-zeroclaw-safe-embeddings.sh --user zeroclaw --disable-embeddings
```

Enable the known working text embedding model:

```sh
sudo ./scripts/configure-zeroclaw-safe-embeddings.sh --user zeroclaw --enable-text-embeddings
```

Enable the backup model only after confirming its deployed vector dimension:

```sh
sudo ./scripts/configure-zeroclaw-safe-embeddings.sh \
  --user zeroclaw \
  --enable-text-embeddings-gemma \
  --embedding-dimensions <TESTED_DIMENSION>
```

The script backs up `/home/zeroclaw/.zeroclaw/config.toml` before editing.

## Verify

Print the current memory config and test only a text embedding request:

```sh
LITELLM_BASE_URL="http://<LITELLM_HOST_IP>:<LITELLM_PORT>/v1" \
LITELLM_CLIENT_KEY="<ZEROCLAW_LITELLM_CLIENT_KEY>" \
./scripts/verify-zeroclaw-embedding-safety.sh --user zeroclaw
```

The verification script intentionally refuses to send image, base64, or `image_url` payloads to `/v1/embeddings`.
Its LiteLLM check is bounded with curl timeouts so an unreachable endpoint fails clearly instead of hanging.

## Optional Source Patch Plan

This repo may not own the ZeroClaw runtime code. If source exists at `/home/zeroclaw/.zeroclaw/src`, use the helper to print the desired upstream/runtime fix:

```sh
./scripts/patch-zeroclaw-sanitize-embeddings.sh --user zeroclaw
```

To write the plan into the source tree for review:

```sh
sudo ./scripts/patch-zeroclaw-sanitize-embeddings.sh --user zeroclaw --apply
```

The source fix should clone the provider payload before memory processing, add `sanitize_for_embedding()`, strip `image_url`/base64/raw media from the embedding copy, skip embedding when no text remains, never mutate the live provider request, and add tests for text-only, image-only, and text+image messages.

## Troubleshooting

Symptoms:

- images break after enabling embeddings
- text-only messages still work
- image-only or text+image messages fail
- the embedding provider receives image markers, base64, or multimodal-looking payloads

Likely cause:

```text
Text embedding pipeline is seeing multimodal payloads.
```

Fast fix:

```sh
sudo ./scripts/configure-zeroclaw-safe-embeddings.sh --user zeroclaw --disable-embeddings
```

Expected verification reminder:

```text
Image payloads should be tested through the vision/chat path, not the embedding path.
```
