import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { apiInitializer } from "discourse/lib/api";

// Adds a "Make public" button to the footer of a chat (a PM with the bot),
// shown only to the chat's owner (or staff). It converts the PM into a public
// topic via the plugin endpoint, then navigates to the new public topic.
export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  const currentUser = api.container.lookup("service:current-user");

  if (!currentUser) {
    return;
  }

  const botUsername = (
    siteSettings.second_brain_bot_username || "stan"
  ).toLowerCase();

  api.registerTopicFooterButton({
    id: "second-brain-make-public",
    icon: "globe",
    priority: 250,
    translatedLabel: "Make public",
    translatedTitle: "Convert this private chat into a public topic",

    displayed() {
      const topic = this.topic;
      if (!topic || !topic.isPrivateMessage) {
        return false;
      }

      const details = topic.details;
      const isOwner = details?.created_by?.id === currentUser.id;
      if (!currentUser.staff && !isOwner) {
        return false;
      }

      const allowedUsers = details?.allowed_users || [];
      return allowedUsers.some(
        (u) => u.username?.toLowerCase() === botUsername
      );
    },

    async action() {
      const topic = this.topic;
      try {
        const result = await ajax(
          `/second-brain/chats/${topic.id}/make_public`,
          { type: "POST" }
        );
        window.location = result.url;
      } catch (error) {
        popupAjaxError(error);
      }
    },
  });
});
