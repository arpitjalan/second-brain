import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { apiInitializer } from "discourse/lib/api";

// A "Widgets" sidebar section listing the term-llm widgets across the member's
// agents (family + their own; personal ones are labelled). Each link opens the
// widget (through our authenticated proxy) in a new tab.

// Fetch the widget list at most once per page load. Core re-instantiates a custom
// sidebar section whenever sidebar state changes (e.g. every keystroke in the
// filter box), so fetching inside the section constructor would spam
// /second-brain/list-widgets and flicker the section. Cache the resolved list so
// re-instantiations read it synchronously.
let widgetsCache = null;
let widgetsPromise = null;
function loadWidgetsOnce() {
  widgetsPromise ||= ajax("/second-brain/list-widgets")
    .then((result) => (widgetsCache = result.widgets || []))
    .catch(() => (widgetsCache = []));
  return widgetsPromise;
}

export default apiInitializer((api) => {
  // Personal, authenticated feature — don't register the section (or its fetch,
  // which anon would 403 on) for logged-out visitors. Matches second-brain-sidebar.
  if (!api.getCurrentUser()) {
    return;
  }

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
        @tracked widgets = widgetsCache || [];

        constructor() {
          super(...arguments);
          // Already loaded this page → read the cache synchronously (no refetch,
          // no flicker). Otherwise fetch once and fill in when it lands.
          if (!widgetsCache) {
            loadWidgetsOnce().then((widgets) => (this.widgets = widgets));
          }
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
