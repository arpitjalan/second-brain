import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { cancel, later } from "@ember/runloop";
import Form from "discourse/components/form";
import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import DiscourseURL from "discourse/lib/url";
import { eq } from "discourse/truth-helpers";
import DButton from "discourse/ui-kit/d-button";
import DModal from "discourse/ui-kit/d-modal";
import { i18n } from "discourse-i18n";

export default class SaveKnowledge extends Component {
  @tracked agents = null;
  @tracked draft = null;
  @tracked generating = false;
  @tracked preview = "";
  @tracked elapsed = 0;
  @tracked queued = false;
  @tracked failed = false;

  #pollTimer = null;

  willDestroy() {
    super.willDestroy(...arguments);
    cancel(this.#pollTimer);
  }

  get sources() {
    return this.args.model.sources;
  }

  @action
  async load() {
    this.failed = false;
    try {
      const data = await ajax("/second-brain/agents");
      if (!this.isDestroying && !this.isDestroyed) {
        this.agents = data.agents;
      }
    } catch {
      if (!this.isDestroying && !this.isDestroyed) {
        this.failed = true;
      }
    }
  }

  @action
  async generate(data) {
    this.generating = true;
    this.preview = "";
    this.elapsed = 0;
    this.queued = true;
    try {
      const result = await ajax("/second-brain/knowledge/draft", {
        type: "POST",
        data: {
          topic_ids: this.sources.map((source) => source.topic_id),
          agent: data.agent,
        },
      });
      if (!this.isDestroying && !this.isDestroyed) {
        this.#poll(result.draft_id);
      }
    } catch (error) {
      if (!this.isDestroying && !this.isDestroyed) {
        this.generating = false;
        popupAjaxError(error);
      }
    }
  }

  @action
  async save(data) {
    try {
      const result = await ajax("/second-brain/knowledge", {
        type: "POST",
        data: {
          topic_ids: this.draft.sources.map((source) => source.id),
          title: data.title,
          raw: data.raw,
          visibility: data.visibility,
          category_id: data.category_id,
        },
      });
      if (this.isDestroying || this.isDestroyed) {
        return;
      }
      this.args.closeModal();
      DiscourseURL.routeTo(result.url);
    } catch (error) {
      popupAjaxError(error);
    }
  }

  async #poll(draftId) {
    try {
      const state = await ajax(`/second-brain/knowledge/drafts/${draftId}`);
      if (this.isDestroying || this.isDestroyed) {
        return;
      }
      if (state.status === "complete") {
        this.draft = state;
        this.generating = false;
      } else if (state.status === "failed") {
        this.generating = false;
        popupAjaxError(i18n("second_brain.knowledge.generation_failed"));
      } else {
        this.preview = state.preview || "";
        this.queued = state.status === "queued";
        this.elapsed = Math.max(
          0,
          Math.floor(Date.now() / 1000) - state.created_at
        );
        this.#pollTimer = later(this, () => this.#poll(draftId), 1500);
      }
    } catch (error) {
      if (!this.isDestroying && !this.isDestroyed) {
        this.generating = false;
        popupAjaxError(error);
      }
    }
  }

  <template>
    <DModal
      class="sb-knowledge"
      @title={{i18n "second_brain.knowledge.action"}}
      @closeModal={{@closeModal}}
    >
      <:body>
        <div {{didInsert this.load}}>
          {{#if this.draft}}
            <p>{{i18n "second_brain.knowledge.review"}}</p>
            <Form @data={{this.draft}} @onSubmit={{this.save}} as |form data|>
              <form.Field
                @name="title"
                @title={{i18n "second_brain.knowledge.title"}}
                @type="input"
                @validation="required"
                as |field|
              >
                <field.Control />
              </form.Field>
              <form.Field
                @name="raw"
                @title={{i18n "second_brain.knowledge.body"}}
                @type="textarea"
                @validation="required"
                as |field|
              >
                <field.Control />
              </form.Field>
              <form.Field
                @name="visibility"
                @title={{i18n "second_brain.knowledge.visibility"}}
                @type="select"
                as |field|
              >
                <field.Control @includeNone={{false}} as |select|>
                  <select.Option @value="private">{{i18n
                      "second_brain.knowledge.private"
                    }}</select.Option>
                  {{#if this.draft.categories.length}}
                    <select.Option @value="shared">{{i18n
                        "second_brain.knowledge.shared"
                      }}</select.Option>
                  {{/if}}
                </field.Control>
              </form.Field>
              {{#if (eq data.visibility "shared")}}
                <form.Field
                  @name="category_id"
                  @title={{i18n "second_brain.knowledge.category"}}
                  @type="select"
                  as |field|
                >
                  <field.Control @includeNone={{false}} as |select|>
                    {{#each this.draft.categories as |category|}}
                      <select.Option
                        @value={{category.id}}
                      >{{category.name}}</select.Option>
                    {{/each}}
                  </field.Control>
                </form.Field>
                <p>{{i18n "second_brain.knowledge.shared_hint"}}</p>
              {{/if}}
              <p class="sb-knowledge__source">
                {{i18n "second_brain.knowledge.source_hint"}}
              </p>
              <form.Submit @label="second_brain.knowledge.save" />
              <DButton
                class="btn-flat"
                @action={{@closeModal}}
                @label="second_brain.knowledge.cancel"
              />
            </Form>
          {{else if this.agents}}
            <p>{{i18n "second_brain.knowledge.setup"}}</p>
            <Form @onSubmit={{this.generate}} as |form|>
              <form.Field
                @disabled={{this.generating}}
                @name="agent"
                @title={{i18n "second_brain.knowledge.agent"}}
                @type="select"
                @validation="required"
                as |field|
              >
                <field.Control as |select|>
                  {{#each this.agents as |agent|}}
                    <select.Option
                      @value={{agent.username}}
                    >{{agent.name}}</select.Option>
                  {{/each}}
                </field.Control>
              </form.Field>
              <form.Submit
                @disabled={{this.generating}}
                @label="second_brain.knowledge.generate"
              />
              {{#if this.generating}}
                <p role="status">{{i18n
                    (if
                      this.queued
                      "second_brain.knowledge.queued"
                      "second_brain.knowledge.generating"
                    )
                    seconds=this.elapsed
                  }}</p>
                {{#if this.preview}}<pre
                    class="sb-knowledge__preview"
                  >{{this.preview}}</pre>{{/if}}
              {{/if}}
            </Form>
          {{else if this.failed}}
            <p role="alert">{{i18n "second_brain.knowledge.failed"}}</p>
            <DButton
              @action={{this.load}}
              @label="second_brain.knowledge.retry"
            />
          {{/if}}
          <h3>{{i18n "second_brain.knowledge.sources"}}</h3>
          <ul>
            {{#each this.sources as |source|}}
              <li><a
                  href={{source.url}}
                  target="_blank"
                  rel="noopener noreferrer"
                >{{source.title}}</a></li>
            {{/each}}
          </ul>
        </div>
      </:body>
    </DModal>
  </template>
}
