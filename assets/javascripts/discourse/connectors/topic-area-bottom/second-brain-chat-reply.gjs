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
import DButton from "discourse/ui-kit/d-button";
import SbAttach from "../../components/sb-attach";

// A frictionless inline reply box at the bottom of a chat (a PM). Type and
// send — no composer. The post is created via the API and appended to the
// stream; the bot's reply then streams in below it like any other post.
export default class SecondBrainChatReply extends Component {
  @service siteSettings;

  @tracked value = "";
  @tracked submitting = false;
  @tracked attachments = [];
  inputEl = null;

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
  registerInput(el) {
    this.inputEl = el;
    this.autoGrow(el);
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
  updateValue(event) {
    this.value = event.target.value;
    this.autoGrow(event.target);
  }

  @action
  handleKeydown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      this.send();
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
  async send() {
    const text = this.value.trim();
    if ((!text && this.attachments.length === 0) || this.submitting) {
      return;
    }
    // Append the uploaded files as markdown; PostCreator links the upload:// refs.
    const raw = [text, this.attachments.map(getUploadMarkdown).join("\n")]
      .filter((part) => part && part.trim())
      .join("\n\n");

    this.submitting = true;
    try {
      const post = await ajax("/posts.json", {
        type: "POST",
        data: { raw, topic_id: this.topic.id },
      });
      this.value = "";
      this.attachments = [];
      next(() => this.autoGrow(this.inputEl)); // shrink back to the default after sending
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
          {{didInsert this.registerInput}}
          {{on "input" this.updateValue}}
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
            <SbAttach @onAdd={{this.addAttachment}} @disabled={{this.submitting}} />
            <span class="sb-starter__link">Enter to send · Shift+Enter for newline</span>
          </span>
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
