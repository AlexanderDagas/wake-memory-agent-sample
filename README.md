# Wake memory agent: validated state updates

A standalone Swift sample adapted from the background memory pipeline in my independent **Wake AI** iOS app. It shows how I separate an LLM's proposed changes from application-owned state, and how I handle failure around that boundary.

The full app uses Gemini for real-time voice conversations and background memory updates. This extracted sample uses a scripted provider response so the state-management behaviour is reproducible without a model account. All example text is synthetic.

## Run it

Requires Swift 6 or later. There are no third-party package dependencies.

```sh
swift test
swift run WakeMemoryDemo
```

The example prints:

```text
Outcome: applied(proposedOperationCount: 1, through: 1)
Acknowledged through: 1
Goal: Finish a portfolio demo
Pending turns: 0
```

## Two-minute code tour

1. [MemoryWorker.swift](Sources/WakeMemoryAgentCore/MemoryWorker.swift): actor isolation, one in-flight request per session, bounded input, request budgets, checkpoints and stale-completion handling.
2. [MemoryValidator.swift](Sources/WakeMemoryAgentCore/MemoryValidator.swift): atomic application of allowed operations against identified user turns; older results cannot overwrite newer corrections.
3. [MemoryWorkerTests.swift](Tests/WakeMemoryAgentCoreTests/MemoryWorkerTests.swift): failure and concurrency cases with controlled providers and an injected clock. No sleeps or live API calls.
4. [RetryState.swift](Sources/WakeMemoryAgentCore/RetryState.swift): minimum spacing, capped backoff and a request budget that does not refill when the clock moves backward.

## Data flow

```text
new conversation turns
    -> bounded pending batch + existing snapshot
    -> MemoryModel proposes structured JSON operations
    -> decode and validate against the source batch
    -> commit candidate state and its input watermark together
```

If decoding, validation or the provider fails, the worker retains the input and returns a retry time with a bounded failure category. Turns arriving during a request remain pending for the next batch. An account/session reset invalidates an old response before it can affect the new session.

The provider gets a value snapshot and source turns, not a reference to the store. Its operations are limited to goals, commitments and preferences in this sample. Other features of the app, including the full mind map, UI, voice transport and live provider integration, are outside this extraction.

## What the tests cover

The 13 tests cover atomic commit and rejection, user-source provenance, update ordering, idempotent repeated proposals, preservation of omitted commitment status, bounded structured output, backoff, daily request limits, duplicate triggers, new input during a request, stale completions after reset, clock rollback and invalid input IDs.

These tests ran locally with Swift 6.4.2 on macOS. The included GitHub Actions workflow runs the package and example with Swift 6.1 on Linux; its first remote result will be available after publication.

## Design boundaries

- Structural validation and source references do **not** prove that a proposed fact is a correct interpretation. Semantic evaluation remains a separate concern.
- This extraction keeps state in memory. An application integrating it must persist snapshots, pending turns and quota state, and schedule the retry times returned by the worker. Wake's original app includes its own persistence and lifecycle handling.
- The scripted adapter is a demonstration of the model boundary, not a live LLM integration or a benchmark of model quality.

This repository is a review sample of one subsystem, not the full Wake app. It was prepared from that app for independent review, with a smaller API and dedicated fixtures/tests.

**Author:** Alexander Dagas
