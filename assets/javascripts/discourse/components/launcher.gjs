import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { fn } from "@ember/helper";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { next } from "@ember/runloop";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { getUploadMarkdown } from "discourse/lib/uploads";
import DiscourseURL from "discourse/lib/url";
import { eq } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import SbAttach from "./sb-attach";

// A few tappable starters that pre-fill the box — they teach a non-technical
// family member what stan can do (research, planning, writing, widgets, Q&A).
const STARTER_CHIPS = [
  {
    label: "📅 Plan this week's dinners",
    prompt: "Plan some easy dinners for this week",
  },
  {
    label: "🌐 Research a weekend trip",
    prompt: "Help me research a fun weekend trip for the family",
  },
  {
    label: "✍️ Help me write a message",
    prompt: "Help me write a message — I'll give you the details.",
  },
  {
    label: "🧩 Make a chore-chart widget",
    prompt: "Make a simple chore chart widget for our family",
  },
  {
    label: "💡 Explain something simply",
    prompt: "Explain something to me simply: ",
  },
];

// Remember which agent a member last chose, so the launcher reopens on it.
// Keyed per user because localStorage is per-browser (a family might share one);
// wrapped in try/catch since storage can be unavailable (e.g. private mode).
const AGENT_STORE_PREFIX = "second_brain:selected-agent:";

function readStoredAgent(userId) {
  try {
    return window.localStorage?.getItem(`${AGENT_STORE_PREFIX}${userId}`);
  } catch {
    return null;
  }
}

function writeStoredAgent(userId, username) {
  try {
    window.localStorage?.setItem(`${AGENT_STORE_PREFIX}${userId}`, username);
  } catch {
    // remembering the choice is a nicety, not essential — ignore storage errors
  }
}

// The homepage. Type a message and go — the plugin creates the private chat
// (a PM with the bot, auto-titled) and navigates into Discourse's message view,
// where the bot replies. No title/recipient friction.
export default class Launcher extends Component {
  @service siteSettings;
  @service currentUser;

  @tracked message = "";
  @tracked starting = false;
  @tracked recent = [];
  @tracked interesting = [];
  @tracked boardLoaded = false;
  @tracked boardError = false;
  @tracked attachments = [];
  @tracked agents = [];
  @tracked selectedAgent = null;
  inputEl = null;

  get botUsername() {
    return this.siteSettings.second_brain_bot_username || "stan";
  }

  // The agent the composer targets — shown as its display name (the bot user's
  // "Full name", which reads as a proper noun like "Stan"), for the lone family
  // agent and a switcher choice alike. Falls back to the configured username
  // before the agents list has loaded.
  get composerBotName() {
    const a = this.agents.find((x) => x.username === this.selectedAgent);
    return a?.name || this.botUsername;
  }

  // Only worth showing the switcher when there's a choice (a personal agent).
  get showAgentSwitcher() {
    return this.agents.length > 1;
  }

  // Time-of-day greeting (local time), personalized when we know who's here.
  // Late night reads as night, not "morning".
  get greeting() {
    const hour = new Date().getHours();
    let part;
    if (hour < 5 || hour >= 23) {
      part = "Working late"; // 23:00–04:59
    } else if (hour < 12) {
      part = "Good morning"; // 05:00–11:59
    } else if (hour < 17) {
      part = "Good afternoon"; // 12:00–16:59
    } else {
      part = "Good evening"; // 17:00–22:59
    }
    // First name only (e.g. "Arpit Jalan" → "Arpit"), falling back to username.
    const firstName = this.currentUser?.name?.trim().split(/\s+/)[0];
    const name = firstName || this.currentUser?.username;
    return name ? `${part}, ${name}` : part;
  }

  get chips() {
    return STARTER_CHIPS;
  }

  get myChatsUrl() {
    return `/u/${this.currentUser.username}/messages`;
  }

  get hasBoard() {
    return this.recent.length > 0 || this.interesting.length > 0;
  }

  // First-run nudge: loaded fine, signed in, but nothing to show yet.
  get showEmptyState() {
    return this.boardLoaded && !this.boardError && !this.hasBoard;
  }

  // The "living brain" board: my recent chats + interesting public topics.
  @action
  async loadBoard() {
    if (!this.currentUser) {
      return;
    }
    try {
      const data = await ajax("/second-brain/home");
      this.recent = data.recent || [];
      this.interesting = data.interesting || [];
      this.boardError = false;
    } catch {
      // Don't silently vanish — tell the user it failed (vs. genuinely empty).
      this.boardError = true;
    } finally {
      this.boardLoaded = true;
    }
  }

  // The agents this member may chat with (family + their own). Defaults the
  // composer to the member's personal agent when they have one.
  @action
  async loadAgents() {
    if (!this.currentUser) {
      return;
    }
    try {
      const data = await ajax("/second-brain/agents");
      this.agents = data.agents || [];
      this.selectedAgent = this.pickDefaultAgent();
    } catch {
      this.agents = [];
    }
  }

  // The agent to open on: the member's last explicit choice if it's still
  // available, else their personal agent, else the family agent.
  pickDefaultAgent() {
    const stored = readStoredAgent(this.currentUser.id);
    if (stored && this.agents.some((a) => a.username === stored)) {
      return stored;
    }
    const owned = this.agents.find((a) => a.owned);
    return owned?.username || this.agents[0]?.username || null;
  }

  @action
  selectAgent(username) {
    this.selectedAgent = username;
    if (this.currentUser) {
      writeStoredAgent(this.currentUser.id, username);
    }
  }

  @action
  registerInput(el) {
    this.inputEl = el;
    this.autoGrow(el);
  }

  @action
  updateMessage(event) {
    this.message = event.target.value;
    this.autoGrow(event.target);
  }

  // Grow the textarea to fit its content; CSS min/max-height set the floor + cap.
  @action
  autoGrow(el) {
    if (!el) {
      return;
    }
    el.style.height = "auto";
    el.style.height = `${el.scrollHeight}px`;
  }

  @action
  useChip(prompt) {
    this.message = prompt;
    // Focus after the value re-renders so the cursor lands at the end.
    next(() => {
      const el = this.inputEl;
      if (el) {
        el.focus();
        el.selectionStart = el.selectionEnd = el.value.length;
        this.autoGrow(el);
      }
    });
  }

  @action
  handleKeydown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      this.start();
    }
  }

  @action
  addAttachment(upload) {
    this.attachments = [...this.attachments, upload];
  }

  @action
  removeAttachment(index) {
    this.attachments = this.attachments.filter((_, i) => i !== index);
  }

  @action
  async start() {
    const text = this.message.trim();
    if ((!text && this.attachments.length === 0) || this.starting) {
      return;
    }
    // Append the uploaded files as markdown; PostCreator links the upload:// refs.
    const message = [text, this.attachments.map(getUploadMarkdown).join("\n")]
      .filter((part) => part && part.trim())
      .join("\n\n");

    const data = { message };
    if (this.selectedAgent) {
      data.agent = this.selectedAgent;
    }

    this.starting = true;
    try {
      const result = await ajax("/second-brain/chats", { type: "POST", data });
      DiscourseURL.routeTo(result.url);
    } catch (error) {
      popupAjaxError(error);
      this.starting = false;
    }
  }

  <template>
    <div
      class="sb-launcher"
      {{didInsert this.loadBoard}}
      {{didInsert this.loadAgents}}
    >
      <h1 class="sb-launcher__title">
        {{#if this.currentUser}}{{this.greeting}}{{else}}Your second brain{{/if}}
      </h1>
      <p class="sb-launcher__subtitle">
        Chat with
        {{this.composerBotName}}
        about anything. It stays private, just for you.
      </p>

      {{#if this.currentUser}}
        {{#if this.showAgentSwitcher}}
          <div
            class="sb-agent-switch"
            role="group"
            aria-label="Choose an agent"
          >
            {{#each this.agents as |a|}}
              <button
                type="button"
                class="sb-agent-switch__pill
                  {{if (eq a.username this.selectedAgent) 'is-active'}}"
                aria-pressed={{if
                  (eq a.username this.selectedAgent)
                  "true"
                  "false"
                }}
                {{on "click" (fn this.selectAgent a.username)}}
              >
                {{a.name}}
              </button>
            {{/each}}
          </div>
        {{/if}}

        <div class="sb-starter">
          <textarea
            class="sb-starter__input"
            aria-label="Message {{this.composerBotName}}"
            placeholder="Message {{this.composerBotName}}…"
            rows="3"
            value={{this.message}}
            disabled={{this.starting}}
            {{didInsert this.registerInput}}
            {{on "input" this.updateMessage}}
            {{on "keydown" this.handleKeydown}}
          ></textarea>
          {{#if this.attachments.length}}
            <div class="sb-attach-files">
              {{#each this.attachments as |file index|}}
                <span class="sb-attach__chip">
                  <span
                    class="sb-attach__name"
                  >{{file.original_filename}}</span>
                  <DButton
                    @action={{fn this.removeAttachment index}}
                    @icon="xmark"
                    @translatedTitle="Remove attachment"
                    class="sb-attach__remove btn-flat"
                  />
                </span>
              {{/each}}
            </div>
          {{/if}}
          <div class="sb-starter__actions">
            <span class="sb-starter__left">
              <SbAttach
                @onAdd={{this.addAttachment}}
                @disabled={{this.starting}}
              />
              <a class="sb-starter__link" href={{this.myChatsUrl}}>Your chats</a>
              <span class="sb-starter__hint">Enter to send · Shift+Enter for newline</span>
            </span>
            <DButton
              @action={{this.start}}
              @translatedLabel="Start chat"
              @icon="paper-plane"
              @disabled={{this.starting}}
              class="btn-primary"
            />
          </div>
        </div>

        <div class="sb-chips">
          {{#each this.chips as |chip|}}
            <button
              type="button"
              class="sb-chips__chip"
              {{on "click" (fn this.useChip chip.prompt)}}
            >
              {{chip.label}}
            </button>
          {{/each}}
        </div>

        {{#if this.boardError}}
          <p class="sb-board__note">
            Couldn't load your chats — refresh to retry.
          </p>
        {{else if this.showEmptyState}}
          <p class="sb-board__note">
            Your chats will show up here once you start one.
          </p>
        {{/if}}

        {{#if this.hasBoard}}
          <div class="sb-board">
            <div class="sb-board__col">
              <h2 class="sb-board__heading">Your recent chats</h2>
              {{#if this.recent.length}}
                {{#each this.recent as |card|}}
                  <a class="sb-board__card" href={{card.url}}>
                    <span class="sb-board__title">{{card.title}}</span>
                    <span class="sb-board__meta">{{card.age}}</span>
                  </a>
                {{/each}}
              {{else}}
                <div class="sb-board__empty">
                  <span class="sb-board__empty-title">No chats yet</span>
                  <span class="sb-board__empty-text">
                    Start one above and it'll show up here.
                  </span>
                </div>
              {{/if}}
            </div>
            {{#if this.interesting.length}}
              <div class="sb-board__col">
                <h2 class="sb-board__heading">Interesting topics</h2>
                {{#each this.interesting as |card|}}
                  <a class="sb-board__card" href={{card.url}}>
                    <span class="sb-board__title">{{card.title}}</span>
                    <span class="sb-board__meta">{{card.username}}
                      ·
                      {{card.age}}</span>
                  </a>
                {{/each}}
              </div>
            {{/if}}
          </div>
        {{/if}}
      {{/if}}
    </div>
  </template>
}
