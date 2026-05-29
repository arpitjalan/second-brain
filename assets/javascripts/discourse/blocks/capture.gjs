import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import { service } from "@ember/service";
import { block } from "discourse/blocks";
import DButton from "discourse/components/d-button";

// The capture block: a frictionless input that is the hero of the homepage.
// The first line of what you type becomes the note (topic) title; the rest
// prefills the body. Submitting opens the composer, so drafts, validation and
// uploads all go through Discourse's normal posting pipeline.
@block("second-brain-capture", {
  description: "Quick-capture box for new notes",
})
export default class CaptureBlock extends Component {
  @service composer;

  @tracked text = "";

  @action
  updateText(event) {
    this.text = event.target.value;
  }

  @action
  handleKeydown(event) {
    // Enter saves; Shift+Enter inserts a newline (default textarea behavior).
    if (event.key === "Enter" && !event.shiftKey) {
      event.preventDefault();
      this.capture();
    }
  }

  @action
  capture() {
    const raw = this.text.trim();
    if (!raw) {
      return;
    }

    const [title, ...rest] = raw.split("\n");
    const body = rest.join("\n").trim();

    this.composer.openNewTopic({
      title: title.trim(),
      body: body.length ? body : null,
    });

    this.text = "";
  }

  <template>
    <div class="sb-capture">
      <textarea
        class="sb-capture__input"
        placeholder="Capture a thought…  (first line becomes the note title)"
        rows="2"
        value={{this.text}}
        {{on "input" this.updateText}}
        {{on "keydown" this.handleKeydown}}
      ></textarea>
      <div class="sb-capture__actions">
        <span class="sb-capture__hint">Enter to save · Shift+Enter for a new
          line</span>
        <DButton
          @action={{this.capture}}
          @translatedLabel="Capture"
          @icon="plus"
          class="btn-primary sb-capture__button"
        />
      </div>
    </div>
  </template>
}
