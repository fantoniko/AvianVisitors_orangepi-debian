# OpenClaw Images API requirements for AvianVisitors

We need a local LAN image-generation API for AvianVisitors to replace the
current Gemini image-generation backend.

AvianVisitors generates separate bird PNG files:

```text
<scientific-slug>.png      # perched pose
<scientific-slug>-2.png    # flight pose
```

After image generation, AvianVisitors runs its own local post-processing:

```sh
cutout.py
build_masks.py
```

So the API only needs to provide a stable image generation endpoint.

## Required API contract

Please provide an OpenAI-compatible endpoint:

```http
POST /v1/images/generations
Authorization: Bearer <LAN_TOKEN>
Content-Type: application/json
```

Request:

```json
{
  "model": "openclaw-image",
  "prompt": "full prompt text here",
  "size": "1024x1024",
  "n": 1,
  "response_format": "b64_json"
}
```

Response:

```json
{
  "created": 1782600000,
  "data": [
    {
      "b64_json": "<base64 encoded PNG or JPEG>"
    }
  ]
}
```

## Hard requirements

- `response_format=b64_json` is required. URL responses are optional, but
  AvianVisitors should be able to read base64 directly.
- `n=1` is enough.
- Minimum required size: `1024x1024`.
- Ideally support:
  - `1024x1024`
  - `1536x1024`
  - `1024x1536`
- Generation may be slow. The client can wait up to 180 seconds.
- The returned image must be a valid PNG or JPEG.
- Errors should return JSON:

```json
{
  "error": {
    "message": "human readable error",
    "type": "generation_error"
  }
}
```

- The service should listen only on the LAN, not on the public internet.
- Bearer-token authentication is required.

## Desired extension: reference images

Gemini currently receives not only a prompt, but also reference images:

1. positive species reference image;
2. optional negative lookalike reference image;
3. style reference image.

If OpenClaw can support reference images, please add this request extension:

```json
{
  "model": "openclaw-image",
  "prompt": "full prompt text here",
  "size": "1024x1024",
  "n": 1,
  "response_format": "b64_json",
  "references": [
    {
      "role": "positive",
      "label": "target species anatomy reference",
      "mime_type": "image/png",
      "b64_json": "<base64>"
    },
    {
      "role": "negative",
      "label": "lookalike species, do not copy",
      "mime_type": "image/jpeg",
      "b64_json": "<base64>"
    },
    {
      "role": "style",
      "label": "Edo-period kacho-e woodblock style reference",
      "mime_type": "image/jpeg",
      "b64_json": "<base64>"
    }
  ]
}
```

If reference images are hard to support initially, we can start without them,
but species accuracy and style consistency will be worse.

## Image quality requirements

The prompt will ask for:

- a single bird on a plain warm cream background;
- Edo-period Japanese kacho-e / woodblock / sumi-e style;
- no branches, water, moon, scenery, text, border, frame, signature, or UI;
- diagnostic field marks matching the scientific and common name;
- poses:
  - `perched`
  - `in flight with wings spread`

The model should avoid:

- adding text;
- adding decorative backgrounds;
- cropping the bird;
- drawing multiple birds;
- replacing a rare species with a common lookalike.

## Example curl

```sh
curl -sS http://openclaw-host.local:8088/v1/images/generations \
  -H 'Authorization: Bearer CHANGE_ME' \
  -H 'Content-Type: application/json' \
  -d '{
    "model": "openclaw-image",
    "prompt": "Draw a single Anna'\''s Hummingbird (Calypte anna), perched, on a plain warm cream background, Edo-period kacho-e woodblock style, no text.",
    "size": "1024x1024",
    "n": 1,
    "response_format": "b64_json"
  }'
```

## Please provide after implementation

1. Base URL, for example:

```text
http://openclaw-host.local:8088
```

2. Bearer token format:

```text
Authorization: Bearer ...
```

3. Model name:

```text
openclaw-image
```

4. Supported sizes.

5. Whether `references` are supported.

6. One working `curl` example.

After that, AvianVisitors can add a provider like this:

```sh
export OPENCLAW_BASE_URL=http://openclaw-host.local:8088
export OPENCLAW_API_KEY=...
python3 avian/scripts/pregen.py \
  --provider openclaw \
  --labels ./labels.txt \
  --force
```
