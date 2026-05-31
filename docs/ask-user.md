# Interactive questions (term-llm `ask_user`)

How the plugin surfaces term-llm's human-in-the-loop **`ask_user`** feature: the
bot pauses mid-run to ask the user structured questions, the user answers inline
in the chat, and the run resumes. Built entirely plugin-side — **no term-llm code
changes** (only a config recommendation, below).

## The term-llm protocol (verified live against a running `serve`)

When the agent calls the built-in `ask_user` tool, the `/v1/responses` SSE stream
emits **`response.ask_user.prompt`** and the run **blocks** server-side waiting for
answers. Crucially, the run is detached from the HTTP connection and keyed by
session id — so a *different* client/process can answer it later.

- **Pause signal** (on the stream): `response.ask_user.prompt`
  ```json
  { "call_id": "call_…", "created_at": 1780…, "questions": [
    { "header": "Trip style", "question": "What kind of weekend trip…?",
      "options": [ { "label": "Road trip", "description": "Easy drive…" }, … ],
      "multi_select": false } ] }
  ```
- **Session id is client-controlled:** send request header `session_id: sb_<topic_id>`
  on `POST /v1/responses`. The run is then addressable by that id.
- **Answer / resume** (connection-independent — term-llm's resume is session-keyed,
  not connection-bound, so a different process can answer later): `POST /v1/sessions/{session_id}/ask_user`
  ```json
  { "call_id": "call_…", "answers": [
    { "question_index": 0, "header": "Trip style", "selected": "Road trip",
      "is_custom": false, "is_multi_select": false } ] }
  ```
  → `200 { "status": "ok", "summary": "Trip style: Road trip | …" }`.
  `404`/`409` once the run is gone/already answered.
- **Stream the continuation:** `GET /v1/responses/{response_id}/events?after={seq}` —
  a live subscription that replays events after `seq` and streams the rest
  (`tool_exec.end`, `output_text.delta…`, `response.completed`, `[DONE]`).
- **SSE framing:** `id: {seq}\nevent: {type}\ndata: {json}\n\n`. `response.created`
  carries `response.id` (the `resp_…` id) and `sequence_number`.

**Validation** (term-llm re-checks, so the UI must match): every question answered;
single-select = an option label, or `is_custom:true` with typed text; multi-select =
non-empty `selected_list`, no custom.

**Constraints we design around:**
- Paused-run state is **in-memory only** → a term-llm restart loses it (answer →
  `410 expired` on our side).
- A paused run times out after `serve.response_timeout` (**default 30 min**). For
  async family answering, run term-llm with a longer value, e.g.
  `--response-timeout 24h` (it just pins one paused runtime in memory; fine at family
  scale). This is the only term-llm-side change recommended, and it's config, not code.

## The Discourse architecture

The mismatch: Discourse streams the run in a **Sidekiq job**, but the user answers
**later from a browser** — a different process. This works because resume is
session-keyed, not connection-bound.

term-llm itself will accept the answer from any process; Discourse adds the access
rule. For the **family/shared** agent, any chat participant may answer. For a
**personal** (owner-private) agent, the `/second-brain/answer` controller restricts
answering to the agent's owner (or staff) — being a PM participant isn't enough.

```
ASK    job → POST /v1/responses (header session_id=sb_<topic_id>), stream
PAUSE  job sees response.ask_user.prompt → persist state on the post → DISCONNECT
         (the run stays alive server-side)
ANSWER user picks options in the post → POST /second-brain/answer {post_id,call_id,answers}
         → controller → POST /v1/sessions/{session_id}/ask_user → 200 + summary
RESUME controller marks the post answered + enqueues a resume job
         → job → GET /v1/responses/{response_id}/events?after={seq}
         → streams the continuation into the same post → finalize
```

### Data model (two post custom fields)

- `second_brain_askuser` (**client-exposed** via `add_to_serializer` + the topic-view
  allowlister): `{ call_id, status, questions, summary }`. `status` ∈
  `pending | answered | done | expired`.
- `second_brain_askuser_state` (**server-only**, never serialized): `{ session_id,
  response_id, last_seq, pre_text }`.

### Code map

| File | Role |
|---|---|
| `lib/second_brain/agent.rb` | `Agent.for_topic` selects the agent participating in the chat (family or personal); `Agent#client` returns a `TermLlmClient` bound to that agent's url/token/model. Streaming/answering goes through `@agent.client` — every term-llm call below is routed via the chat's agent |
| `lib/second_brain/term_llm_client.rb` | `stream_respond(session_id:)` parses the `id:`/`response.created`/`ask_user.prompt` events and returns `{text,tools,ask_user,response_id,last_seq}`; `stream_events(response_id:,after:)` reconnects; `submit_ask_user(...)` answers (raises `Expired` on 404/409) — passing `cancelled: true` skips the question (sends `{cancelled:true}` instead of `answers`), and the controller records `skipped`/returns `skipped:true` |
| `lib/second_brain/bot_responder.rb` | `respond!`→`conclude` pauses or finalizes; `pause_for_ask_user` persists state + refreshes clients once; `resume!` streams the continuation, seeded with the pre-prompt text |
| `app/controllers/second_brain/chats_controller.rb` | `answer` — validates, submits to term-llm, marks answered, enqueues the resume job (`410` on expiry) |
| `app/jobs/regular/second_brain_reply.rb` | `mode: "resume"` → `resume!` |
| `plugin.rb` | custom-field registration, allowlister + serializer, `POST /second-brain/answer` |
| `assets/javascripts/.../second-brain-askuser.js` | renders the inline form (radios / checkboxes / "Other"), submits, shows the answered summary / expiry |

The form is built in the DOM (from the serialized field), never in cooked HTML, so
the sanitizer never strips it — same pattern as the widget/copy decorators. It
appears via a one-time `:revised` refresh when the run pauses, and survives reload
via the serialized field.

## v1 scope

- ✅ Single-select (radios + free-text **Other**) **and** multi-select (checkboxes) —
  multi-select was folded in because the real bot emits it immediately.
- ✅ Full round-trip: ask → pause → answer → resume → continue, including a second
  question round if the continuation asks again.
- ✅ Expiry handling (term-llm restart / timeout → `410` → "ask again" note).
- ⏳ Deferred: a paginated stepper (v1 stacks all questions), a live countdown to the
  deadline, durable cross-restart persistence (needs term-llm work).

## Manual test plan (needs a browser — restart Rails first; Ruby changed)

The answer endpoint's access/privacy behavior is now covered by
`spec/requests/second_brain/chats_controller_spec.rb`; the manual plan still covers
the full browser round-trip + expiry the specs don't.

1. Run term-llm with `--response-timeout 24h` (optional but recommended).
2. In a chat, send a query that makes stan ask, e.g. *"Help me research a fun weekend
   trip for the family."* The bot post should show the inline question form.
3. Answer (mix a radio, a checkbox group, and an **Other** typed answer) → **Send
   answers**. The form collapses to "You answered — …" and stan's reply streams in
   below it.
4. Reload mid-question (before answering) → the form should still be there.
5. Expiry: restart term-llm while a question is pending, then answer → expect the
   "this question expired" note (the `410` path).
