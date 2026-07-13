# Generating illustrations

The collage art is generated, not hand-drawn. The repository does not ship
pre-generated illustration PNGs; build a set for your own region with the
four-script pipeline in this directory. Run the examples below from the
repository root.

## Pipeline

1. `pregen.py` renders each bird with Gemini 2.5 Flash Image or a local
   OpenClaw-compatible image API, on a flat cream ground.
2. `cutout.py` removes the ground with BiRefNet and crops to the bird.
3. `build_masks.py` rebuilds the external `dims.json` and `masks.json` manifests.
4. `verify.py` (optional) runs an adversarial species-ID + anatomy check.

```bash
python3 -m venv .venv-cutout
. .venv-cutout/bin/activate
python -m pip install --upgrade pip wheel
python -m pip install -r avian/scripts/requirements.txt

export GEMINI_API_KEY='your-key'

# 1. generate (cream ground) for your region's species
python avian/scripts/pregen.py --labels ~/BirdNET-Pi/model/labels.txt --ebird-region US-CA

# 2. cut the ground off and crop
python avian/scripts/cutout.py

# 3. rebuild the collage manifests, then bump SKETCH_VERSION + IMG_VERSION in apt.js
python avian/scripts/build_masks.py
```

`--labels` takes any `Sci|Com` per-line file (BirdNET-Pi's `labels.txt` works
directly). `--ebird-region` filters to species actually seen in your region
(needs `EBIRD_API_KEY`). Re-render one bird with
`--species "Calypte anna|Anna's Hummingbird" --force`.

To use a LAN OpenClaw image proxy instead of Gemini:

```bash
export OPENCLAW_BASE_URL='http://openclaw-host.local:8088'
export OPENCLAW_API_KEY='your-lan-token'

python avian/scripts/pregen.py \
  --provider openclaw \
  --labels ~/BirdNET-Pi/model/labels.txt \
  --openclaw-size 1024x1024 \
  --force
```

The OpenClaw provider calls `/v1/images/generations` with
`response_format=b64_json` and sends the same anatomy, anti-lookalike, and style
reference images through the project-specific `references` request field when
those files are available. If your local proxy does not yet support that
extension, add `--no-refs` to generate from text prompts only.

After OpenClaw generation, run `cutout.py` before checking the collage. The raw
image model output is intentionally a flat paper rectangle; `cutout.py` is what
turns it into transparent RGBA artwork. The default `u2netp` model is selected
to keep unattended runs within modest memory limits. Process a few slugs at a
time:

```bash
. .venv-cutout/bin/activate
python avian/scripts/cutout.py parus-major --force
python avian/scripts/cutout.py turdus-merula --force
python avian/scripts/cutout.py cyanistes-caeruleus --force
python avian/scripts/build_masks.py
```

On a host with plenty of spare RAM, the heavier BiRefNet model can be selected
for potentially finer edges:

```bash
python avian/scripts/cutout.py turdus-merula --force --model birefnet-general
python avian/scripts/build_masks.py
```

Verify transparency with:

```bash
python - <<'PY'
from PIL import Image
for slug in ["parus-major", "turdus-merula", "cyanistes-caeruleus"]:
    im = Image.open(f"avian/assets/illustrations/{slug}.png").convert("RGBA")
    print(slug, im.getchannel("A").getextrema())
PY
```

Each processed image should report an alpha range like `(0, 255)`. `(255, 255)`
means the square background is still opaque.

## Why a cream ground

The image model can't cut a clean transparent background on its own: it
leaves holes and fringes, worst on pale birds. Rendering on a flat,
consistent cream ground gives a known color that BiRefNet removes cleanly,
and the steady ground also holds the painting style together across the
whole set. `cutout.py` is the step that makes the backgrounds transparent.

## The prompt

`prompt.template.md` is the kachō-e prompt, sent verbatim per request with
`{sci_name}`, `{com_name}`, and `{pose}` substituted. Edit it to change the
style. `pregen.py` attaches up to three reference images per request:

- **Anatomy** (IMAGE 1): a Wikipedia photo of the target species, auto-fetched
  and cached in `assets/references/`. Anchors identity and markings. Drop your
  own `references/<slug>.jpg` to override.
- **Anti-reference** (IMAGE 2, optional): a photo of a look-alike the model
  drifts toward, captioned with what NOT to copy. Wired for blue corvids (vs
  Blue Jay) and swallows (vs Barn Swallow); add more in the `ANTI_REFS` table
  and place photos at `references/_anti_<key>.jpg`.
- **Style** (IMAGE 3, optional): a real Edo-period kachō-e print whose painting
  technique is borrowed. The genus-to-print mapping is in `pregen.py`'s
  `STYLE_REFS`. The prints are not bundled (they are someone else's art); put
  your own in `assets/references/styles/`. The Koson and Yoshida prints used
  originally are easy to find on the public web by the filenames in `STYLE_REFS`.

All three degrade gracefully: a missing reference is simply not attached.

For a one-off manual image in ChatGPT Plus, without using the Gemini/API
pipeline, use `manual-chatgpt-collage.prompt.md`. Paste the latest bird counts
from your installation into its `CURRENT BIRD DATA` block and ask ChatGPT to
generate a single finished collage image. This does not update the bundled PNG
library or frontend masks; it is for manual poster-style output.

## Hard species

`species-notes.json` holds one-line diagnostic addenda for species the model
gets wrong. Each note names the field marks that matter and the look-alikes to
avoid, and is appended to the prompt for that species. Add entries as you find
drift; they carry forward to every future regeneration of that bird.

## Verifying

`verify.py` sends each illustration back through Gemini Vision without telling
it the target species, then checks the guess, the wing/leg/tail counts, and
whether a stray perch crept in. It catches drift a quick eyeball misses.

```bash
python3 verify.py --labels labels.txt              # whole library -> verify-results.csv
python3 verify.py --labels labels.txt calypte-anna
```

## What actually goes wrong

- **Sticks.** Perched raptors often come back gripping a twig the prompt
  forbade. Generate 2-3 and keep the clean one.
- **Species drift.** The model collapses an uncommon species toward a common
  look-alike (a swift becomes a swallow). Fixes, in order: a sharper
  `species-notes.json` note with anti-feature language; an anti-reference; a
  different style print; a one-off `--species` regen.
- **Matched pair.** The perched and flight poses must read as the same
  individual. Review them side by side before locking.
