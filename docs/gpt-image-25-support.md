# GPT Image 2.5 support (2026-09-09)

## Contract and scope

The built-in OpenAI and Codex OAuth candidate lists now include
`gpt-image-2.5-sunburst` and `gpt-image-2.5-flare`. Manual entries using their
`-2026-09-08` snapshots are also recognized. These models accept text/reference
images and produce images, not text. Existing Image 2 entries, defaults, hidden
flags and user overrides are preserved.

Sources checked using the OpenAI Docs skill:

- [Sunburst model](https://developers.openai.com/api/docs/models/gpt-image-2.5-sunburst)
- [Flare model](https://developers.openai.com/api/docs/models/gpt-image-2.5-flare)
- [Image generation and Responses tool selection](https://developers.openai.com/api/docs/guides/image-generation)
- [Image edit request fields](https://developers.openai.com/api/reference/resources/images/methods/edit)

## Request behavior

- API key: keep `/images/generations` and `/images/edits`, including custom
  endpoint behavior. Send the selected image model, size and quality. Do not
  add legacy `response_format=b64_json` for 2.5; GPT image output is already
  base64. Reference image files use consistent `image[]` multipart fields.
- Codex OAuth: use the Responses image tool. The outer `model` remains a text
  model; `tools[0].model` is the exact selected 2.5 variant/snapshot. Pass size
  and quality to the tool. Do not retry as Image 2 if the server rejects 2.5.
- Quick Test and model-use share the OAuth route gate. Image 2 keeps its legacy
  bare tool request. Unsupported `n` values in OAuth produce a caller warning.
- Model-use help now lists 2.5 quality values, including `xhigh` and `max`,
  instead of suggesting DALL-E's `hd` for these models.

## Verification and limitations

- Five Image 2.5 helper tests plus seven existing GPT-6 helper tests run against
  production sources in a temporary macOS Swift package: 12 passed.
- iOS integration tests cover catalog/metadata, auth routing, request model
  separation, reference images and idempotent refresh preserving user settings.
  Device-target `xcodebuild build-for-testing` passed (Debug, unsigned); these
  integration tests were compiled, not executed on a device. `git diff --check`
  also passed. Existing project warnings remain.
- Public API support does **not** prove access through the undocumented Codex
  OAuth backend or a particular ChatGPT subscription. The OAuth list remains
  explicitly labeled as built-in candidates, not an account availability check.
  No live image generation or paid API call was made for this change.

After installing a build containing this change, use **Refresh** in the OpenAI
provider settings to add both entries, then use Quick Test with the intended
account. Server access/version errors must remain visible; no silent downgrade.
