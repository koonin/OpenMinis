# iOS thinking controls

The typing indicator means a request is waiting for content, not that the model
has emitted reasoning. It now reads “Waiting for reply” (等待回复).

The session picker, title badge, information card, restored thinking blocks and
OpenAI agent requests use the effective thinking level. Legacy saved `off`
preferences remain intact; they resolve to the connection's minimum when Off is
unavailable, so switching to a model that supports Off can still honor the preference.
An explicitly selected Off in a draft also survives first-send group-default seeding.

For Codex OAuth, model refresh retains `supported_reasoning_levels` separately
from models.dev metadata. Account tiers survive caching, backups and entry overrides.
Only an account declaration of `none` enables Off; unknown/old Codex metadata keeps
the existing Low fallback, now labeled honestly. API capabilities alone are not
evidence of Codex capabilities. The observed Codex catalog for GPT-6 Sol/Luna did
not advertise `none`, even though their API models support it.

GPT-6 Astra and GPT-6.1 Sol remain always-reasoning models. Their old Off preference
resolves to the minimum, rather than sending an unsupported `none` request.
Actual Off sends `reasoning.effort: none` without requesting a reasoning summary.
Other providers' existing parameter rules are unchanged.

References: [OpenAI reasoning guide](https://developers.openai.com/api/docs/guides/reasoning),
[GPT-6 Sol API capabilities](https://developers.openai.com/api/docs/models/gpt-6-sol).

## Regression checks

`ThinkingOffBehaviorTests` covers minimums, API versus Codex capabilities, wire
parameters, sparse account tiers, old saves, metadata preservation and draft Off.
GPT-6.1 Sol/Astra integration and existing thinking-rule tests are also exercised.

Two existing Qwen tests fail on the unmodified `bd78ea8` baseline as well:
`ThinkingRulesRegressionTests.testQwenDualSendsAtRootAndExtraBody` and
`ThinkingWireGoldenSnapshotTests.testGoldenSnapshotOfEveryBranch`.
Their assertions and production Qwen emitter are deliberately unchanged here.
