# GPT Image 2.5 reference-image editing fix (2026-09-09)

## Evidence

The provided conversation export records three separate problems:

1. Initially no models were available to `minis-model-use`; the assistant used
   a Pillow filter rather than model-based image editing.
2. It incorrectly advised using the Vision Input group. That group describes
   images in text; model-use authorization is controlled by Agent Loop Models.
3. After a confirmed authorization change, a Sunburst request included a JPEG
   data URL, but the assistant reported local rejection for missing image input.
   Screenshots also show only `img-out` for these saved entries. The old export
   omits raw tool-result-only messages, so the exact tool error/phone settings
   cannot be recovered from this archive alone.

The [official Sunburst contract](https://developers.openai.com/api/docs/models/gpt-image-2.5-sunburst)
accepts reference images. The prior adaptation only supplied defaults at model
creation; persisted non-nil output-only metadata and subsequent catalog
enrichment could still omit image input. The local preflight checks this
metadata before any provider request.

## Changes

- Verified OpenAI Image 2.5 base capabilities are applied both during metadata
  enrichment and when reading a persisted ModelEntry. No delete/re-add required.
- Explicit user capability overrides still win. Names, entry IDs, hidden state,
  credentials, groups and model-use authorization are unchanged. Other models
  and provider namespaces are not normalized by this repair.
- Vision Input picker/resolver require image input AND text output, keeping
  image-only output models out of the image-description route. Its explanation
  now distinguishes image description from image generation in Chinese.
- Model-use listings identify capability metadata vs explicit overrides. Local
  preflight errors say no provider request was sent, rather than presenting a
  local configuration issue as a vendor limitation.
- Agent guidance requires the actual source image for editing, explains the
  authorization setting, and forbids silently substituting local filters for
  requested model-based restyling. It does not authorize configuration changes.

## Validation

Added iOS integration regressions for output-only persisted records, exact
variant/snapshot preservation, JPEG data in the actual Responses request,
enrichment/inference, preservation of explicit overrides, and separation from
Vision Input. These are compiled with `build-for-testing`; account-specific
Codex OAuth image editing still needs a live test after installation. Public API
documentation is not proof of Codex backend/subscription availability.

If image input remains disabled after installation, inspect the explicit
capability override on that entry. It is intentionally not silently overwritten.
