# Manual ChatGPT collage prompt

Use this prompt when you want to generate a one-off AvianVisitors-style collage
manually in ChatGPT Plus, without using the Gemini/API pre-generation pipeline.

Paste current bird data into the `CURRENT BIRD DATA` block before sending. Keep
the rows sorted by call count descending so the generated image reflects the
latest activity around the microphone.

To get current data directly on the BirdNET-Pi device, run:

```sh
sqlite3 -readonly "$HOME/BirdNET-Pi/scripts/birds.db" "
SELECT
  Com_Name || ' | ' || Sci_Name || ' | calls: ' || COUNT(*) ||
  ' | best confidence: ' || ROUND(MAX(Confidence), 2) ||
  ' | last seen: ' || MAX(Date || ' ' || Time)
FROM detections
WHERE (julianday('now','localtime') - julianday(Date || ' ' || Time)) * 24 <= 24
GROUP BY Sci_Name, Com_Name
ORDER BY COUNT(*) DESC
LIMIT 30;"
```

Change `24` to another hour window if needed. If `sqlite3` is not installed but
the AvianVisitors web API is running, open this URL on the device and paste the
returned species data into the prompt:

```text
http://127.0.0.1:8079/avian/api/birdnet-api.php?action=recent&hours=24
```

Suggested data format:

```text
CURRENT BIRD DATA
Window: last 24 hours
Location/season: <city/region, month, habitat>

1. Anna's Hummingbird | Calypte anna | calls: 42 | notes: common, tiny, iridescent magenta throat
2. House Finch | Haemorhous mexicanus | calls: 18 | notes: red male, brown-streaked body
3. California Scrub-Jay | Aphelocoma californica | calls: 7 | notes: blue head/wings, gray back, no crest
```

If you only have scientific/common names, omit the notes. If ChatGPT asks for an
image, you can attach the current screenshot of the existing collage as a layout
reference, but the prompt below is intended to work from text alone.

---

## Prompt

Create a single finished illustration: a live bird collage from my listening
station, based on the exact current bird data below.

CURRENT BIRD DATA:

```text
<paste current bird rows here>
```

Goal:

Render one cohesive poster-like collage containing every species listed in
CURRENT BIRD DATA. The image should look like an AvianVisitors collage: many
individual birds arranged as a natural flock/cloud, with each bird shown as a
clean cutout-like illustration on a plain warm cream paper background.

Style:

- Edo-period Japanese kacho-e woodblock print influence.
- Confident sumi-e ink linework, soft watercolor washes, flat color zones.
- Restrained natural palette: ochre, burnt umber, indigo, muted green,
  vermillion, warm gray, cream.
- Sparse, elegant, field-guide readable, not photorealistic.
- No text labels, no captions, no borders, no signatures, no UI.
- No branches, leaves, perches, scenery, water, moon, sky, frame, or decorative
  background elements. Only birds on warm cream paper.

Data mapping:

- Include every species in CURRENT BIRD DATA exactly once.
- Size each bird by relative call count: the highest-count species should be the
  largest, rare species smaller but still recognizable.
- Keep all birds visible and uncropped.
- Species with similar call counts should have similar visual size.
- Do not invent extra species not listed in CURRENT BIRD DATA.

Species accuracy:

- Match each species' diagnostic field marks, proportions, bill shape, tail
  shape, and color pattern.
- Prefer adult breeding plumage unless the notes say otherwise.
- Do not collapse uncommon species into better-known look-alikes.
- If a species has a note, follow it over generic bird assumptions.
- Close relatives must remain distinguishable from each other.

Composition:

- Arrange birds by silhouette, as if they nest together without rectangular
  overlap.
- Largest birds sit near the visual center.
- Smaller birds fill the gaps around them.
- Use a balanced cluster with generous negative space around the outside.
- The result should read as a single intentional collage, not a grid and not
  separate stickers.
- Use mixed natural poses: mostly perched/floating side views, with a few birds
  in flight if appropriate.

Output requirements:

- Landscape image, 16:9 or 4:3.
- High resolution.
- Warm cream paper background.
- Entire bird bodies visible: head, beak, wings, tail, legs/feet when relevant.
- No text anywhere in the image.
- No humans, feeders, houses, logos, watermarks, or interface elements.

Before generating, silently check that the number of birds in the image matches
the number of species in CURRENT BIRD DATA.
