import { tracked } from "@glimmer/tracking";
import { ajax } from "discourse/lib/ajax";
import { apiInitializer } from "discourse/lib/api";

// A "Widgets" sidebar section listing the family's term-llm widgets. Each link
// opens the widget through our authenticated proxy.
export default apiInitializer((api) => {
  api.addSidebarSection(
    (BaseCustomSidebarSection, BaseCustomSidebarSectionLink) => {
      class WidgetLink extends BaseCustomSidebarSectionLink {
        constructor(widget) {
          super(...arguments);
          this.widget = widget;
        }

        get name() {
          return `second-brain-widget-${this.widget.mount}`;
        }

        get title() {
          return this.widget.title;
        }

        get text() {
          return this.widget.title;
        }

        get href() {
          return `/second-brain/widgets/${this.widget.mount}/`;
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
