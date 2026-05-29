import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import { on } from "@ember/modifier";
import { service } from "@ember/service";
import DButton from "discourse/components/d-button";
import { defaultHomepage } from "discourse/lib/utilities";
import { i18n } from "discourse-i18n";

// The capture box: a frictionless input pinned to the top of the homepage.
// The first line of what you type becomes the note (topic) title; any
// remaining lines prefill the body. Submitting opens the composer so the
// full Discourse posting pipeline (drafts, validation, uploads) stays intact.
export default class CaptureBox extends Component {
  @service router;
  @service composer;
  @service site;
  @service siteSettings;

  @tracked text = "";

  get isHomepage() {
    return this.router.currentRouteName === `discovery.${defaultHomepage()}`;
  }

  get captureCategory() {
    const id = parseInt(this.siteSettings.second_brain_capture_category, 10);
    if (isNaN(id)) {
      return null;
    }
    return this.site.categories?.find((c) => c.id === id) ?? null;
  }

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
      category: this.captureCategory,
    });

    this.text = "";
  }

  <template>
    {{#if this.isHomepage}}
      <div class="second-brain-capture">
        <textarea
          class="second-brain-capture__input"
          placeholder={{i18n "second_brain.capture.placeholder"}}
          rows="2"
          value={{this.text}}
          {{on "input" this.updateText}}
          {{on "keydown" this.handleKeydown}}
        ></textarea>
        <div class="second-brain-capture__footer">
          <span class="second-brain-capture__hint">
            {{i18n "second_brain.capture.hint"}}
          </span>
          <DButton
            @action={{this.capture}}
            @label="second_brain.capture.button"
            @icon="plus"
            class="btn-primary second-brain-capture__button"
          />
        </div>
      </div>
    {{/if}}
  </template>
}
