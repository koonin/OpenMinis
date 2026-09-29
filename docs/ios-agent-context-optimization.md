# iOS Agent context optimization — first pass

This change reduces repeated context while preserving access to source data.
It does not change model selection, reasoning levels, memory retrieval limits,
context-window thresholds, cache keepalive frequency, or Android behavior.

## Changes

- Shell execution returns its complete sanitized output to the tool dispatcher.
  The dispatcher persists it before generating a preview. Previously, shell
  execution discarded the middle before the dispatcher saved the "full" file.
- For shell/browser results exceeding 15,000 characters, the model receives
  6,000 characters of head/tail text plus the file path and retrieval hint.
  Smaller results and explicit file-read budgets keep their existing behavior.
  Successful persistence still exposes the encoded `minis_url`.
- File-save failures produce an explicit warning and the existing 15,000
  character preview, without claiming that a complete file exists. Offload
  names include a UUID to avoid collisions between concurrent calls.
- Compaction distinguishes an active task handoff from a historical summary.
  Active handoffs retain pending work, blockers and next steps while respecting
  cancellations and superseding instructions. Recursive split retries carry
  the previous summary into the first segment exactly once and propagate the
  compaction mode to every segment.
- Repeated memory guidance is consolidated and injected only when enabled.
  Global-memory instructions consistently require explicit authorization for
  edits. Skill metadata is rendered in stable ID order after selection; the
  existing recency/frequency selection policy is unchanged.
- Compaction, title generation and cache warmup now record provider-reported
  usage in a separate `auxiliary_usage` SQLite table. The existing usage view
  includes these records without creating chat messages or changing context.
  A request UUID merges repeated/partial cumulative stream snapshots using
  per-counter maxima. Each explicit retry gets a new UUID. Attribution is
  captured from the request's model rather than a later session selection.

## Accounting scope

The auxiliary ledger is device-local and contains only identifiers, model
metadata, request kind, start time and token counters. It is not included in
the semantic session sync/export format. Rows survive deletion of a session;
they represent usage already incurred. Existing message-based accounting is
unchanged, including its deletion semantics.

This is not a complete provider invoice: historical auxiliary usage cannot be
reconstructed; calls without provider usage events cannot be measured; other
paths such as standalone model-use/voice/folder suggestions are not covered by
this change. Subscription percentages and monetary prices are not inferred
from token totals. UI totals may increase simply because formerly omitted
requests are now counted.

## Verification

The offline tests compile production support code and exercise Unicode output
round-trips, omitted middle evidence, boundary sizes, write failure, SQLite
reopening, repeated/partial usage events, independent retries and model
attribution. The handoff test extracts the production recursive splitter at
run time and forces multiple splits using an offline summarizer.

```sh
swiftc src/ios/Agent/Chat/AgentContextSupport.swift \
  scripts/test_agent_context_support.swift -o /tmp/test-agent-context
/tmp/test-agent-context
python3 scripts/test_compaction_handoff.py
swift scripts/test_compact_orphan_toolcall.swift
```

All three passed. The first suite contains 41 assertions. The existing compact
suite also checks that its tested pairing logic matches the production source.

The simulator build passed Swift compilation but cannot link the device-only
`deps/libs/libish_emu.a`; see the simulator note in `BUILDING.md`.
The full Debug build for `generic/platform=iOS` subsequently succeeded with
`CODE_SIGNING_ALLOWED=NO`. Project-file validation (`plutil -lint`) and
`git diff --check` also passed.

On the user's installation request, `scripts/build_install_ios.sh` rebuilt
with signing, verified the signature and `group.com.koon.minis` entitlement,
then installed and launched `com.koon.minis` on the paired iPhone 17 Pro.
This verifies installation and launch, not an end-to-end model quality or
cost comparison.

## Measuring the next pass

The large-output preview body is 60% smaller (15,000 → 6,000 characters).
This is not a measured reduction in total tokens or cost. No paid model calls
were made for this change, so model-level quality equivalence is not claimed.

Compare the same model/configuration on: finding evidence in the middle of a
large log; extracting facts from a long web page; continuing an interrupted
multi-step task across compaction; recalling a relevant memory; and a simple
chat that should need no tools. Record completion/correctness, extra retrieval
calls, retries, elapsed time, and provider-reported input/output/cache usage,
including auxiliary requests. Do not reduce memory budgets or change cache
keepalive policy on the basis of prompt length alone.
