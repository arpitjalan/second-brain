import { apiInitializer } from "discourse/lib/api";
import { i18n } from "discourse-i18n";
import SaveKnowledge from "../components/modal/save-knowledge";

export default apiInitializer((api) => {
  if (!api.getCurrentUser()) {
    return;
  }

  const modal = api.container.lookup("service:modal");

  api.registerTopicFooterButton({
    id: "second-brain-knowledge",
    icon: "book-open",
    priority: 260,
    translatedLabel: i18n("second_brain.knowledge.action"),
    translatedTitle: i18n("second_brain.knowledge.action"),

    displayed() {
      return this.topic?.isPrivateMessage && this.topic.second_brain_agent;
    },

    action() {
      modal.show(SaveKnowledge, {
        model: {
          sources: [
            {
              topic_id: this.topic.id,
              title: this.topic.title,
              url: `/t/${this.topic.id}`,
            },
          ],
        },
      });
    },
  });
});
