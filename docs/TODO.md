# Deferred work / TODO

Known items intentionally left for later, with enough detail to pick up cold.
Each says **why it's deferred** and **how to do it safely** so we don't trade a
working feature for a fix.

---

## 1. Isolate widget iframes off the Discourse origin (security — HIGH)

**Status:** deferred. Real fix carries regression risk to the working widget
feature, so it must ship behind a flag with a fallback (see "Safe rollout").

### The problem

term-llm widgets are LLM-generated mini-apps (some are live servers, e.g.
`job-usage`). We reverse-proxy them through Discourse and embed them in an iframe:

- Proxy: `app/controllers/second_brain/widgets_controller.rb` — `#show` serves
  the widget at `/second-brain/widgets/<path>` (the **Discourse origin**),
  `requires_login`, injects the term-llm Bearer token server-side, and sets a
  permissive `WIDGET_CSP`.
- Iframe: `assets/javascripts/discourse/api-initializers/second-brain-widgets.js`
  — `frame.setAttribute("sandbox", "allow-scripts allow-same-origin allow-forms allow-popups")`.
- Link rewriting: `lib/second_brain/bot_responder.rb#proxy_widget_links`
  rewrites `…/widgets/…` → `/second-brain/widgets/…`.
- Sidebar list: `…/api-initializers/second-brain-widgets-sidebar.js` +
  `WidgetsController#index`.

Because the iframe's origin **is** Discourse's origin and `allow-same-origin`
is set, the widget's JS runs **as Discourse**. A hostile widget (term-llm could
be steered into generating one via prompt-injection from content the bot read)
can, riding the logged-in user's session cookie:

- `fetch('/session/current.json')`, `/u/<user>.json`, `/t/<pm-id>.json` — read
  the account and private chats;
- read the CSRF token from `/session/csrf` and **POST as the user** (publish,
  message, change settings);
- reach `window.parent.document`, `localStorage`, etc.

`frame-ancestors 'self'` and the httpOnly session cookie do **not** help — the
calls are same-origin, so the cookie is attached automatically. Effectively
stored-XSS scoped to whoever opens the widget.

### Why we can't just drop `allow-same-origin`

The widgets are **dynamic**: at runtime they `fetch` their backend through the
proxy and some use `localStorage`. Without `allow-same-origin` the iframe runs in
an **opaque/null origin** → `localStorage` throws and same-origin fetches break →
dynamic widgets die. Removal is a regression, not a fix.

There's also **no safe partial**: tightening the CSP `connect-src` to `'self'`
does nothing here, because on a same-origin iframe `'self'` *is* Discourse's
origin — the widget can still reach Discourse's API.

### The fix — give widgets their own origin

Standard sandbox-content pattern (GitHub `*.githubusercontent.com`, Google
`*.googleusercontent.com`): serve the proxy from a **different host** so
`allow-same-origin` grants the widget *its own* isolated origin.

1. **Separate origin** — e.g. `widgets.<forum-host>`. `WidgetsController#show`
   answers there; add it to `config.hosts`; ideally a host-constrained route so
   only the proxy responds there (or a tiny standalone Rack service for max
   isolation — the widget host then never runs Discourse code).
2. **Cross-origin auth grant** (the crux — `requires_login` breaks because the
   Discourse session cookie won't, and shouldn't, cross to the widget host).
   When Discourse renders the widget link, mint a **short-lived, user-scoped,
   HMAC-signed grant** and embed it **as a path prefix**:
   `https://widgets.<host>/w/<grant>/<widget-path>`. The widget's *relative*
   subresource fetches inherit `/w/<grant>/…` automatically, so they're
   authorized **without any cookie** — which also sidesteps third-party-cookie
   blocking. The widget host validates the grant (sig + expiry + user), then
   proxies to term-llm with the Bearer token exactly as today.
3. **Sandbox unchanged** (`allow-scripts allow-same-origin …`) — but now
   `allow-same-origin` = the *widget* origin. localStorage/fetch keep working in
   the widget's own world; Discourse cookies/API/DOM are cross-origin and
   unreachable.
4. **CSP** — set the widget response's `frame-ancestors https://<forum-host>`
   (only Discourse may embed it). Keep the Discourse session cookie host-scoped
   (it is) so the subdomain can't read it.

**Dev:** cheap — `widgets.localhost` resolves to 127.0.0.1 with no cert, so
`http://widgets.localhost:3000/w/<grant>/…` is testable. **Prod:** needs a DNS
record + a SAN/wildcard cert for the subdomain, plus the `config.hosts` entry.

### Lighter alternative (no subdomain, with trade-offs)

Drop `allow-same-origin` (null origin) and inject a small shim into the proxied
HTML that tunnels the widget's `fetch`/`localStorage` to a trusted parent-page
broker over `postMessage` (the broker allowlists + performs the proxied calls).
No subdomain, full isolation — but **fragile** against widgets that use
non-`fetch` mechanisms (WebSocket, `EventSource`, dynamic `<script>`). The
separate-origin approach is the robust one.

### The regression risk (why this is gated)

Widgets are externally-defined and reference assets/APIs in ways we don't
control. The grant-in-path scheme only authorizes **relative** subresource
requests — any widget using **root-absolute** paths (`/api/…`) would have its
fetches miss the grant prefix and break. A first cut would plausibly break
loading for *some* existing widgets (job-usage, Skill Manager, …), discoverable
only by testing each.

### Safe rollout

- Put the new origin behind a site setting (e.g. `second_brain_widget_host`);
  empty = current same-origin behavior (the fallback).
- Keep `proxy_widget_links` + the iframe builder emitting the same-origin URL
  when the setting is empty, the new origin when set.
- Flip it on in dev first; load **every** real widget and confirm it renders +
  its data calls work. Only then consider it for prod.
- Roll back = clear the setting.

### Threat-model note

For the current ~5-person trusted family the urgency is **moderate** — the
realistic vector is the bot generating a hostile widget after ingesting injected
external content. Do this before the bot reads much untrusted web content, or
before any less-trusted member joins.

---

## 2. Family agent + per-user agents (feature — SHIPPED)

Shared family `stan` + opt-in per-user personal agents (distinct named bots, one
term-llm container each, behind the `second_brain_agents` registry). Personal
agents are TL4 (non-admin), private to their owner; the launcher defaults to your
agent (last choice remembered) with a switcher. Multiple agents per owner work.
**Design in `docs/design-multi-agent.md`.** Merged to `main`.

**Personal widgets — handled (was a known limitation).** A personal agent's
widget is proxied at `/second-brain/agent-widgets/<agent>/<mount>/`, so its
*relative* subresource fetches inherit the agent. The worry was *absolute* refs
(`/chat/widgets/…` or `/second-brain/widgets/…`) escaping to the family proxy.
Empirically, current term-llm widgets use **only relative paths** (verified by
fetching the real HTML of job-usage/orbitarium/skill-manager/time-hn-notes — zero
absolute refs), so this didn't bite in practice. As cheap insurance,
`WidgetsController#rewrite_widget_base` now rewrites any absolute widget-base ref
in the **HTML document** back to the owning agent's prefix (no-op on today's
widgets; spec'd). **Residual:** absolute URLs built in **JS at runtime** still
aren't covered — that's the same problem the separate-origin work (item 1) solves
properly. Not a cross-user leak either way (no token exposure).

---

## Other confirmed-but-deferred items (from the code-review sweep)

Real findings the review verified but that need design/tests, so they were not
auto-fixed:

- **Resumed reply drops the pre-pause tool summary** (`bot_responder.rb`
  `resume!` / `pause_for_ask_user`). Persist `pre_tools` in the server state and
  read them back **with symbol keys** (`transform_keys(&:to_sym)` — render code
  uses symbols, `JSON.parse` yields strings). Wants a spec
  (tools→ask→resume→tools), which is why it's deferred.
- **Reply job swallows non-network errors with no user-visible resolution**
  (`app/jobs/regular/second_brain_reply.rb`). Partly mitigated by the broadened
  connection-error rescues; the blanket case interacts with `claim_turn!`
  (a second attempt no-ops) so resolving the placeholder safely is a design call.
- **No reply-flow / ask_user spec harness yet.** Request + agent specs now exist
  (`spec/lib/second_brain/agent_spec.rb`,
  `spec/requests/second_brain/{chats,widgets}_controller_spec.rb` — 23 examples),
  covering agent access/privacy + the widget proxy, but NOT the streaming reply →
  ask_user → resume path. A spec harness for that flow would let several of the
  above (e.g. the `pre_tools` fix) land safely.

These came from a multi-agent review (45 findings → 33 real → 19 low-hanging,
all of which are fixed as of commit `7eceff3`).
