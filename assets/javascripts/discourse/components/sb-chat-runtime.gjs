import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import didUpdate from "@ember/render-modifiers/modifiers/did-update";
import Form from "discourse/components/form";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DButton from "discourse/ui-kit/d-button";
import { i18n } from "discourse-i18n";

export default class SbChatRuntime extends Component {
  @tracked draftModel = "";
  @tracked editing = false;
  @tracked failed = false;
  @tracked loading = true;
  @tracked settings = null;

  #loadId = 0;

  get launcher() {
    return !this.args.topic;
  }

  get efforts() {
    return (
      this.settings?.models.find((model) => model.id === this.draftModel)
        ?.efforts || []
    );
  }

  get defaultsLabel() {
    const defaults = this.settings?.defaults;
    if (!defaults?.model) {
      return i18n("second_brain.runtime.model_unknown");
    }
    return [defaults.model, defaults.reasoning_effort]
      .filter(Boolean)
      .join(" · ");
  }

  get defaultsOptionLabel() {
    return i18n("second_brain.runtime.defaults", {
      selection: this.defaultsLabel,
    });
  }

  get selectionLabel() {
    const selection = this.settings;
    if (!selection?.model) {
      return this.defaultsLabel;
    }
    const model = selection.models.find(
      (entry) => entry.id === selection.model
    );
    const effort = selection.reasoning_effort || model?.default_effort;
    return [selection.model, effort].filter(Boolean).join(" · ");
  }

  @action
  async load() {
    const loadId = ++this.#loadId;
    this.editing = false;
    this.failed = false;
    this.loading = true;
    this.settings = null;
    try {
      const settings = this.launcher
        ? await ajax("/second-brain/agent-runtime", {
            data: { agent: this.args.agent },
          })
        : await ajax(`/second-brain/chats/${this.args.topic.id}/runtime`);
      if (loadId === this.#loadId && !this.isDestroying && !this.isDestroyed) {
        this.settings = settings;
      }
    } catch {
      if (loadId === this.#loadId && !this.isDestroying && !this.isDestroyed) {
        this.failed = true;
      }
    } finally {
      if (loadId === this.#loadId && !this.isDestroying && !this.isDestroyed) {
        this.loading = false;
      }
    }
  }

  @action
  changeModel(value, { set }) {
    this.draftModel = value || "";
    set("model", value);
    set("reasoning_effort", null);
  }

  @action
  toggle() {
    this.draftModel = this.settings.model;
    this.editing = !this.editing;
  }

  @action
  async save(data) {
    if (this.launcher) {
      const selection = {
        model: data.model || "",
        reasoning_effort: data.reasoning_effort || "",
      };
      this.args.onChange(selection);
      this.settings = { ...this.settings, ...selection };
      this.editing = false;
      return;
    }
    const topicId = this.args.topic.id;
    try {
      const selection = await ajax(`/second-brain/chats/${topicId}/runtime`, {
        type: "PUT",
        data: {
          model: data.model || "",
          reasoning_effort: data.reasoning_effort || "",
        },
      });
      if (
        this.isDestroying ||
        this.isDestroyed ||
        this.args.topic.id !== topicId
      ) {
        return;
      }
      this.settings = { ...this.settings, ...selection };
      this.editing = false;
    } catch (error) {
      popupAjaxError(error);
    }
  }

  <template>
    <div
      class="sb-runtime"
      {{didInsert this.load}}
      {{didUpdate this.load @topic.id @agent}}
    >
      {{#if this.loading}}
        <span>{{i18n "second_brain.runtime.loading"}}</span>
      {{else if this.failed}}
        <span>{{i18n "second_brain.runtime.unavailable"}}</span>
        <DButton
          class="btn-flat"
          @action={{this.load}}
          @label="second_brain.runtime.retry"
        />
      {{else}}
        <div class="sb-runtime__summary">
          <span>{{i18n
              (if
                this.launcher
                "second_brain.runtime.first_reply"
                "second_brain.runtime.next_reply"
              )
              selection=this.selectionLabel
            }}</span>
          <DButton
            class="btn-flat"
            @action={{this.toggle}}
            @disabled={{@disabled}}
            @label="second_brain.runtime.configure"
          />
        </div>
        {{#if this.editing}}
          <Form @data={{this.settings}} @onSubmit={{this.save}} as |form|>
            <form.Field
              @disabled={{@disabled}}
              @name="model"
              @onSet={{this.changeModel}}
              @title={{i18n "second_brain.runtime.model"}}
              @type="select"
              as |field|
            >
              <field.Control
                @nonePlaceholder={{this.defaultsOptionLabel}}
                as |select|
              >
                {{#each this.settings.models as |model|}}
                  <select.Option
                    @value={{model.id}}
                  >{{model.id}}</select.Option>
                {{/each}}
              </field.Control>
            </form.Field>
            <form.Field
              @disabled={{if
                @disabled
                true
                (if this.efforts.length false true)
              }}
              @name="reasoning_effort"
              @title={{i18n "second_brain.runtime.effort"}}
              @type="select"
              as |field|
            >
              <field.Control
                @nonePlaceholder={{i18n "second_brain.runtime.default_effort"}}
                as |select|
              >
                {{#each this.efforts as |effort|}}
                  <select.Option @value={{effort}}>{{effort}}</select.Option>
                {{/each}}
              </field.Control>
            </form.Field>
            {{#if this.draftModel}}
              {{#unless this.efforts.length}}
                <p>{{i18n "second_brain.runtime.no_efforts"}}</p>
              {{/unless}}
            {{/if}}
            <p>{{i18n
                (if
                  this.launcher
                  "second_brain.runtime.applies_first"
                  "second_brain.runtime.applies_next"
                )
              }}</p>
            <form.Submit
              @disabled={{@disabled}}
              @label={{if
                this.launcher
                "second_brain.runtime.use_for_chat"
                "second_brain.runtime.save"
              }}
            />
            <DButton
              class="btn-flat"
              @action={{this.toggle}}
              @label="second_brain.runtime.cancel"
            />
          </Form>
        {{/if}}
      {{/if}}
    </div>
  </template>
}
