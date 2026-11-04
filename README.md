# Wake AI — selected implementation

**Swift · iOS · Gemini Live · LLM tool orchestration**

Wake AI is my independent voice coaching app. Its real-time conversation agent uses tools to manage conversation state, while a background model updates persistent memory and a visual mind map for later sessions.

This repository presents selected **actual application source** for code review. Start with the live-session integration to see how the pieces connect.

## Code guide

1. **[Live voice orchestration and recovery](Excerpts/GeminiLiveSession.excerpts.swift)** — serialised WebSocket messages; generation checks that fence stale callbacks; quiet-boundary connection renewal; resumable-session handoff and transcript fallback; bounded retries; independently ordered transcript/tool events; asynchronous tool review and response handling.
2. **[Conversation tools and state](Excerpts/CallTopicNotebook.swift)** — tool schemas, argument validation, app-owned caller evidence, bounded topic history, rejected-choice feedback, duplicate/cancelled request handling, and output gating while a decision is pending. This is the complete component file.
3. **[Background memory and mind-map updates](Excerpts/MemoryDistiller.excerpts.swift)** — structured model operations, actor-isolated single-flight work, coalesced triggers, source-turn validation, request budgets, persisted retry state, and acknowledgement of input only after an accepted update.

## How they connect

The live session receives speech/transcript events and model-proposed tool calls. The topic router and notebook validate those calls against the current conversation and return structured results. Session and request checks prevent stale asynchronous work from being applied to a later connection or exchange.

Separately, completed turns become input to the memory distiller. It asks the model for structured operations, validates fact updates against source turns, applies accepted updates through application-owned stores, and retains pending input on failure. That state supplies context for future conversations.

## Scope

The excerpt files preserve the original method bodies. Their extension wrappers and source-line comments are added for presentation; surrounding types, stored properties, UI, credentials, provider setup and other app code are omitted. These files are intended to be read in context and do not form a standalone build.

The topic component also contains explicitly opt-in atomic-transition, caller-choice and continuation experiments. Inclusion does not mean every experimental path is enabled in the app. Protocol and source checks constrain model actions; semantic conversation quality still requires separate evaluation.

**Author:** [Alexander Dagas](https://www.linkedin.com/in/AlexanderDagas)
