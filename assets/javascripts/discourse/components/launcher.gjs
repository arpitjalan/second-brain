import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DiscourseURL from "discourse/lib/url";

// The homepage. Type a message and go — the plugin creates the private chat
// (a PM with the bot, auto-titled) and navigates into Discourse's message view,
// where the bot replies. No title/recipient friction.
export default class Launcher extends Component {
  @service siteSettings;
  @service currentUser;

  @tracked message = "";
  @tracked starting = false;

  get botUsername() {
    return this.siteSettings.second_brain_bot_username || "stan";
  }

  get myChatsUrl() {
    return `/u/${this.currentUser.username}/messages`;
  }

  @action
  updateMessage(event) {
    this.message = event.target.value;
  }

  @action
  handleKeydown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      this.start();
    }
  }

  @action
  async start() {
    const message = this.message.trim();
    if (!message || this.starting) {
      return;
    }

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
    <div class="sb-launcher">
      <h1 class="sb-launcher__title">Your second brain</h1>
      <p class="sb-launcher__subtitle">
        Chat privately with {{this.botUsername}}. Press Enter to start — every chat
        is private by default.
      </p>

      {{#if this.currentUser}}
        <div class="sb-starter">
          <textarea
            class="sb-starter__input"
            placeholder="Message {{this.botUsername}}…"
            rows="3"
            value={{this.message}}
            disabled={{this.starting}}
            {{on "input" this.updateMessage}}
            {{on "keydown" this.handleKeydown}}
          ></textarea>
          <div class="sb-starter__actions">
            <a class="sb-starter__link" href={{this.myChatsUrl}}>Your chats</a>
            <DButton
              @action={{this.start}}
              @translatedLabel="Start chat"
              @icon="paper-plane"
              @disabled={{this.starting}}
              class="btn-primary"
            />
          </div>
        </div>
      {{/if}}
    </div>
  </template>
}
