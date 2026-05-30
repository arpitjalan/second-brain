import { apiInitializer } from "discourse/lib/api";

// Live-paints the bot's streamed reply. The server publishes partial cooked
// HTML to "/second-brain/stream" (delivered only to the chat's participants),
// and we drop it straight into the post's .cooked element — no refetch.
export default apiInitializer((api) => {
  const messageBus = api.container.lookup("service:message-bus");
  if (!messageBus) {
    return;
  }

  messageBus.subscribe("/second-brain/stream", (data) => {
    if (!data || !data.post_id || typeof data.html !== "string") {
      return;
    }

    const cooked = document.querySelector(
      `article[data-post-id="${data.post_id}"] .cooked`
    );
    if (cooked) {
      cooked.innerHTML = data.html;
    }
  });
});
