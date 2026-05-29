import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import DButton from "discourse/components/d-button";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";

// Ask the brain: posts a question to the plugin's server-side proxy, which
// forwards it to term-llm and returns the answer. Non-streaming for now —
// streaming + web-search/widget rendering build on this.
export default class AskBrain extends Component {
  @tracked question = "";
  @tracked answer = null;
  @tracked loading = false;

  @action
  updateQuestion(event) {
    this.question = event.target.value;
  }

  @action
  handleKeydown(event) {
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      this.ask();
    }
  }

  @action
  async ask() {
    const question = this.question.trim();
    if (!question || this.loading) {
      return;
    }

    this.loading = true;
    this.answer = null;

    try {
      const result = await ajax("/second-brain/ask", {
        type: "POST",
        data: { question },
      });
      this.answer = result.answer;
    } catch (error) {
      popupAjaxError(error);
    } finally {
      this.loading = false;
    }
  }

  <template>
    <div class="sb-ask">
      <div class="sb-ask__bar">
        <input
          type="text"
          class="sb-ask__input"
          placeholder="Ask your brain anything…"
          value={{this.question}}
          {{on "input" this.updateQuestion}}
          {{on "keydown" this.handleKeydown}}
        />
        <DButton
          @action={{this.ask}}
          @translatedLabel="Ask"
          @icon="bolt"
          @disabled={{this.loading}}
          class="btn-primary sb-ask__button"
        />
      </div>

      {{#if this.loading}}
        <p class="sb-ask__status">Thinking…</p>
      {{else if this.answer}}
        <div class="sb-ask__answer">{{this.answer}}</div>
      {{/if}}
    </div>
  </template>
}
