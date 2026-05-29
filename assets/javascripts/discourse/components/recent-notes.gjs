import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { trustHTML } from "@ember/template";
import { service } from "@ember/service";

// Recent notes: the latest topics, rendered as calm cards beneath the capture
// box. `@limit` caps how many we show.
export default class RecentNotes extends Component {
  @service store;

  @tracked notes = [];
  @tracked loading = true;

  constructor() {
    super(...arguments);
    this.load();
  }

  get limit() {
    return this.args.limit ?? 12;
  }

  async load() {
    try {
      const list = await this.store.findFiltered("topicList", {
        filter: "latest",
      });
      this.notes = (list?.topics ?? []).slice(0, this.limit);
    } finally {
      this.loading = false;
    }
  }

  <template>
    <section class="sb-recent">
      <h2 class="sb-recent__heading">Recent notes</h2>

      {{#if this.loading}}
        <p class="sb-recent__status">Loading…</p>
      {{else if this.notes.length}}
        <ul class="sb-recent__list">
          {{#each this.notes as |note|}}
            <li class="sb-note">
              <a class="sb-note__title" href={{note.url}}>
                {{trustHTML note.fancyTitle}}
              </a>
              {{#if note.excerpt}}
                <p class="sb-note__excerpt">{{trustHTML note.excerpt}}</p>
              {{/if}}
            </li>
          {{/each}}
        </ul>
      {{else}}
        <p class="sb-recent__status">No notes yet — capture your first thought
          above.</p>
      {{/if}}
    </section>
  </template>
}
