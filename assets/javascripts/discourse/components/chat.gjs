import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import DButton from "discourse/components/d-button";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";

// A chat with the assistant (term-llm). Keeps the conversation in memory and
// sends the full history each turn. Persistence (private-by-default, shareable)
// and streaming build on this.
export default class Chat extends Component {
  @tracked messages = [];
  @tracked draft = "";
  @tracked loading = false;

  @action
  updateDraft(event) {
    this.draft = event.target.value;
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
    const text = this.draft.trim();
    if (!text || this.loading) {
      return;
    }

    this.messages = [...this.messages, { role: "user", content: text }];
    this.draft = "";
    this.loading = true;

    try {
      const result = await ajax("/second-brain/ask", {
        type: "POST",
        contentType: "application/json",
        data: JSON.stringify({ messages: this.messages }),
      });
      this.messages = [
        ...this.messages,
        { role: "assistant", content: result.answer },
      ];
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.loading = false;
    }
  }

  <template>
    <div class="sb-chat">
      <div class="sb-chat__log">
        {{#each this.messages as |message|}}
          <div class="sb-chat__msg sb-chat__msg--{{message.role}}">
            {{message.content}}
          </div>
        {{/each}}
        {{#if this.loading}}
          <div class="sb-chat__msg sb-chat__msg--assistant sb-chat__msg--pending">
            Thinking…
          </div>
        {{/if}}
      </div>

      <div class="sb-chat__composer">
        <textarea
          class="sb-chat__input"
          placeholder="Message your assistant…"
          rows="2"
          value={{this.draft}}
          {{on "input" this.updateDraft}}
          {{on "keydown" this.handleKeydown}}
        ></textarea>
        <DButton
          @action={{this.send}}
          @translatedLabel="Send"
          @icon="paper-plane"
          @disabled={{this.loading}}
          class="btn-primary sb-chat__send"
        />
      </div>
    </div>
  </template>
}
