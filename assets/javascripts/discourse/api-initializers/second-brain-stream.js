import { apiInitializer } from "discourse/lib/api";

// Live-paints the bot's streamed reply. The server publishes partial cooked
// HTML to "/second-brain/stream" (delivered only to the chat's participants).
// We update the post MODEL's cooked so Ember re-renders it — setting innerHTML
// directly gets reverted by Ember on its next render.
export default apiInitializer((api) => {
  const messageBus = api.container.lookup("service:message-bus");
  if (!messageBus) {
    return;
  }

  messageBus.subscribe("/second-brain/stream", (data) => {
    if (!data || !data.post_id || typeof data.html !== "string") {
      return;
    }

    const topicController = api.container.lookup("controller:topic");
    const postStream = topicController?.model?.postStream;
    const post = postStream?.findLoadedPost?.(data.post_id);

    // Temporary diagnostic — remove once streaming is confirmed.
    // eslint-disable-next-line no-console
    console.log(
      "[second-brain] stream chunk",
      "post=" + data.post_id,
      "html=" + data.html.length,
      "done=" + !!data.done,
      "postFound=" + !!post
    );

    if (post) {
      post.set("cooked", data.html);
    }
  });
});
