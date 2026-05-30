import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";

// A frictionless inline reply box at the bottom of a chat (a PM). Type and
// send — no composer. The post is created via the API and appended to the
// stream; the bot's reply then streams in below it like any other post.
export default class SecondBrainChatReply extends Component {
  @service siteSettings;

  @tracked value = "";
  @tracked submitting = false;

  get topic() {
    return this.args.outletArgs.model;
  }

  // Chats are PMs; only show the inline box there, not on public topics.
  get isChat() {
    return this.topic?.isPrivateMessage;
  }

  get botUsername() {
    return this.siteSettings.second_brain_bot_username || "stan";
  }

  @action
  updateValue(event) {
    this.value = event.target.value;
  }

  @action
  handleKeydown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      this.send();
    }
  }

  @action
  async send() {
    const raw = this.value.trim();
    if (!raw || this.submitting) {
      return;
    }

    this.submitting = true;
    try {
      const post = await ajax("/posts.json", {
        type: "POST",
        data: { raw, topic_id: this.topic.id },
      });
      this.value = "";
      // Append our new post (no-ops if the message bus already added it).
      await this.topic.postStream.triggerNewPostsInStream([post.id], {
        background: false,
      });
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.submitting = false;
    }
  }

  <template>
    {{#if this.isChat}}
      <div class="sb-chat-reply sb-starter">
        <textarea
          class="sb-starter__input"
          placeholder="Message {{this.botUsername}}…"
          rows="2"
          value={{this.value}}
          disabled={{this.submitting}}
          {{on "input" this.updateValue}}
          {{on "keydown" this.handleKeydown}}
        ></textarea>
        <div class="sb-starter__actions">
          <span class="sb-starter__link">Enter to send · Shift+Enter for newline</span>
          <DButton
            @action={{this.send}}
            @translatedLabel="Send"
            @icon="paper-plane"
            @disabled={{this.submitting}}
            class="btn-primary"
          />
        </div>
      </div>
    {{/if}}
  </template>
}
