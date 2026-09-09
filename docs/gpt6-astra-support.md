# GPT-6 Astra support

## Cause and scope

The ChatGPT-login model picker used `allOpenAICodexOAuth`, a static seven-model
list. Refreshing reloaded that list and enriched existing IDs; it did not
discover models or check the logged-in account's access. The refresh result
incorrectly reported its source as `api`.

The fix adds `gpt-6-astra` as a catalog candidate and labels the source honestly
as `built-in`, with an account-access warning in English and Chinese. It does
not change any existing default/group selection. Existing users can tap Refresh
after installing the updated app; no account deletion or re-login is required.
Refresh retains custom entries, hidden state, UUIDs and user overrides through
the existing merge path. This is not a new server-side model-discovery service;
future catalog additions still require maintenance.

## Request compatibility

Official references checked 2026-09-07:

- https://developers.openai.com/api/docs/models/gpt-6-astra
- https://developers.openai.com/api/docs/guides/latest-model

Built-in/manual Astra entries have offline context, output, vision and reasoning
metadata. Official OpenAI requests use the existing Responses implementation,
including tool calls. Third-party, Azure and explicit endpoint routing remains
user-controlled. Other model IDs are unaffected.

At serialization, Astra requests drop unsupported sampling/logprob controls;
`none`/`minimal` become `low`, and the client-side `ultra` becomes `max`.
Supported efforts, tool data, summary settings and encrypted reasoning are kept.
The UI's thinking-off setting cannot fully disable reasoning on this model.

## Verification boundaries

`GPT6AstraSupportTests` runs the production request/routing helper in a temporary
macOS Swift package, without credentials or network. `GPT6AstraIntegrationTests`
covers the actual app catalog, provider routing and model-entry refresh merge.
Building these tests is separate from executing them on iOS. No live account
access or successful GPT-6 generation is claimed by the catalog or host tests.

On 2026-09-07, all seven host tests passed, and the final iPhoneOS Debug
`build-for-testing` succeeded (app, extensions and test targets). The four
app-integration tests were compiled but not executed on a phone. This pass did
not commit, push, or install the changed app.

## Follow-up: Codex client-version rejection

After installation, a real phone request returned HTTP 400 stating that Astra
requires a newer Codex version. Both OAuth request paths still advertised
`0.144.1`. The protocol adapter baseline is now `0.153.4`, an official release
with Astra catalog support listed at https://learn.chatgpt.com/docs/changelog.
This is a verified released version, not a claim about the server's exact
minimum version. Version, User-Agent, beta and originator headers now share one
helper; credentials and account headers are unchanged. An additional integration
test checks their consistency and preservation of authentication headers.

The follow-up passed signed iPhoneOS build-for-testing and app build. Automatic
model quick-test attempts could not reach the phone's debug server over network
or USB forwarding, so a successful live generation is still not verified here.
