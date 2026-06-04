import Component from "@glimmer/component";
import { tracked } from "@glimmer/tracking";
import { on } from "@ember/modifier";
import { action } from "@ember/object";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import { debounce } from "@ember/runloop";
import { ajax } from "discourse/lib/ajax";

// The search-your-chats widget (its own page, reachable from the sidebar). Hits
// the scoped GET /second-brain/search; another member's private chats are never
// in the candidate set (server-side owner/participant scoping).
export default class SbSearch extends Component {
  @tracked query = "";
  @tracked results = [];
  @tracked pending = false;
  @tracked done = false;
  @tracked error = false;
  seq = 0; // discards out-of-order/stale responses

  get hasQuery() {
    return this.query.trim().length >= 2;
  }

  @action
  focusInput(el) {
    el?.focus();
  }

  @action
  update(event) {
    this.query = event.target.value;
    // Clear the prior verdict so a stale "No matches"/error can't show while a
    // new query is still being typed or fetched.
    this.done = false;
    this.error = false;
    debounce(this, this.run, 250);
  }

  @action
  async run() {
    const q = this.query.trim();
    if (q.length < 2) {
      this.results = [];
      this.done = false;
      this.error = false;
      return;
    }
    const seq = ++this.seq;
    this.pending = true;
    try {
      const data = await ajax("/second-brain/search", { data: { q } });
      if (seq !== this.seq) {
        return; // a newer query superseded this one — drop the stale response
      }
      this.results = data.results || [];
      this.error = false;
    } catch {
      if (seq !== this.seq) {
        return;
      }
      this.results = [];
      this.error = true;
    } finally {
      if (seq === this.seq) {
        this.pending = false;
        this.done = true;
      }
    }
  }

  <template>
    <div class="sb-search">
      <input
        type="search"
        class="sb-search__input"
        placeholder="Search your chats…"
        aria-label="Search your chats"
        value={{this.query}}
        {{didInsert this.focusInput}}
        {{on "input" this.update}}
      />
    </div>

    {{#if this.hasQuery}}
      {{#if this.results.length}}
        <div class="sb-board sb-board--search">
          <div class="sb-board__col sb-board__col--full">
            {{#each this.results as |card|}}
              <a class="sb-board__card" href={{card.url}}>
                <span class="sb-board__title">{{card.title}}</span>
                {{#if card.blurb}}
                  <span class="sb-board__blurb">{{card.blurb}}</span>
                {{/if}}
                <span class="sb-board__meta">{{card.username}}
                  ·
                  {{card.age}}</span>
              </a>
            {{/each}}
          </div>
        </div>
      {{else if this.error}}
        <p class="sb-board__note">Search failed — try again.</p>
      {{else if this.done}}
        <p class="sb-board__note">No chats match “{{this.query}}”.</p>
      {{/if}}
    {{/if}}
  </template>
}
