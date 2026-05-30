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
  inputEl = null;

  get botUsername() {
    return this.siteSettings.second_brain_bot_username || "stan";
  }

  // Time-of-day greeting, personalized when we know who's here.
  get greeting() {
    const hour = new Date().getHours();
    const part =
      hour < 12
        ? "Good morning"
        : hour < 18
          ? "Good afternoon"
          : "Good evening";
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

  @action
  registerInput(el) {
    this.inputEl = el;
  }

  @action
  updateMessage(event) {
    this.message = event.target.value;
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

    this.starting = true;
    try {
      const result = await ajax("/second-brain/chats", {
        type: "POST",
        data: { message },
      });
      DiscourseURL.routeTo(result.url);
    } catch (error) {
      popupAjaxError(error);
      this.starting = false;
    }
  }

  <template>
    <div class="sb-launcher" {{didInsert this.loadBoard}}>
      <h1 class="sb-launcher__title">
        {{#if this.currentUser}}{{this.greeting}}{{else}}Your second brain{{/if}}
      </h1>
      <p class="sb-launcher__subtitle">
        Chat privately with
        {{this.botUsername}}. Every chat is private by default.
      </p>

      {{#if this.currentUser}}
        <div class="sb-starter">
          <textarea
            class="sb-starter__input"
            aria-label="Message {{this.botUsername}}"
            placeholder="Message {{this.botUsername}}…"
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
                  <span class="sb-attach__name">{{file.original_filename}}</span>
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
              <SbAttach @onAdd={{this.addAttachment}} @disabled={{this.starting}} />
              <a class="sb-starter__link" href={{this.myChatsUrl}}>Your chats</a>
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
            {{#if this.recent.length}}
              <div class="sb-board__col">
                <h2 class="sb-board__heading">Your recent chats</h2>
                {{#each this.recent as |card|}}
                  <a class="sb-board__card" href={{card.url}}>
                    <span class="sb-board__title">{{card.title}}</span>
                    <span class="sb-board__meta">{{card.age}}</span>
                  </a>
                {{/each}}
              </div>
            {{/if}}
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
