import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { apiInitializer } from "discourse/lib/api";

// A "Widgets" sidebar section listing the term-llm widgets across the member's
// agents (family + their own; personal ones are labelled). Each link opens the
// widget (through our authenticated proxy) in a new tab.
export default apiInitializer((api) => {
  // The widget links are same-origin (our proxy), so Discourse's built-in
  // "external links in new tab" never triggers. Open them in a new tab via a
  // delegated handler scoped to our section (survives re-renders; guarded so
  // dev hot-reloads don't stack duplicate listeners). Runs in the CAPTURE phase
  // so preventDefault lands before Discourse's bubble-phase click interceptor —
  // which bails on defaultPrevented, so it won't also route the same tab.
  if (!window.__sbWidgetNewTab) {
    window.__sbWidgetNewTab = true;
    document.addEventListener(
      "click",
      (event) => {
        const link = event.target.closest("a[href]");
        if (
          link?.closest('[data-section-name="second-brain-widgets"]') &&
          /\/second-brain\/(agent-)?widgets\//.test(link.getAttribute("href") || "")
        ) {
          event.preventDefault();
          window.open(link.href, "_blank", "noopener");
        }
      },
      true
    );
  }

  api.addSidebarSection(
    (BaseCustomSidebarSection, BaseCustomSidebarSectionLink) => {
      class WidgetLink extends BaseCustomSidebarSectionLink {
        constructor(widget) {
          super(...arguments);
          this.widget = widget;
        }

        get name() {
          return `second-brain-widget-${this.widget.agent || "family"}-${this.widget.mount}`;
        }

        get title() {
          return this.widget.owned
            ? `${this.widget.title} · ${this.widget.agent}`
            : this.widget.title;
        }

        get text() {
          return this.title;
        }

        get href() {
          return this.widget.url || `/second-brain/widgets/${this.widget.mount}/`;
        }

        get prefixType() {
          return "icon";
        }

        get prefixValue() {
          return "puzzle-piece";
        }
      }

      return class extends BaseCustomSidebarSection {
        @tracked widgets = [];

        constructor() {
          super(...arguments);
          ajax("/second-brain/list-widgets")
            .then((result) => {
              this.widgets = result.widgets || [];
            })
            .catch(() => {
              this.widgets = [];
            });
        }

        get name() {
          return "second-brain-widgets";
        }

        get title() {
          return "Widgets";
        }

        get text() {
          return "Widgets";
        }

        get links() {
          return this.widgets.map((widget) => new WidgetLink(widget));
        }

        get displaySection() {
          return this.widgets.length > 0;
        }
      };
    }
  );
});
