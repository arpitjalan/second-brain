import { apiInitializer } from "discourse/lib/api";
import loadMorphlex from "discourse/lib/load-morphlex";

// Live-paints the bot's streamed reply. The server publishes partial cooked HTML
// to "/second-brain/stream" (delivered only to the chat's participants).
//
// In the Glimmer post stream (the only mode since Discourse 2026.x), setting
// post.cooked does NOT re-render the post mid-stream — it only takes effect on a
// full render. So, exactly like Discourse's own AI streamer, we morph the rendered
// ".cooked" DOM directly while streaming (and preventCloak so the post isn't
// unloaded under us), then write the model's cooked once on the final message.
const MORPH_OPTIONS = {
  // Don't fight the user toggling a <details> (our collapsible tool-call block)
  // open/closed while new content streams in.
  beforeAttributeUpdated: (element, attributeName) =>
    !(element.tagName === "DETAILS" && attributeName === "open"),
};

export default apiInitializer((api) => {
  const messageBus = api.container.lookup("service:message-bus");
  if (!messageBus) {
    return;
  }

  messageBus.subscribe("/second-brain/stream", async (data) => {
    if (!data || !data.post_id || typeof data.html !== "string") {
      return;
    }

    const topicController = api.container.lookup("controller:topic");
    const postStream = topicController?.model?.postStream;
    const post = postStream?.findLoadedPost?.(data.post_id);
    if (!post) {
      return;
    }

    // Final message: write the model so the component renders it canonically and
    // the post can be cloaked again.
    if (data.done) {
      post.set("cooked", data.html);
      api.preventCloak?.(data.post_id, false);
      return;
    }

    // Mid-stream: morph the live DOM. Fall back to the model if the post element
    // isn't on screen yet (then a later render shows the latest cooked anyway).
    const topicId = postStream.topic?.id;
    const cookedEl = document.querySelector(
      `.topic-area[data-topic-id="${topicId}"] #post_${post.post_number} .cooked`
    );
    if (!cookedEl) {
      post.set("cooked", data.html);
      return;
    }

    api.preventCloak?.(data.post_id);
    (await loadMorphlex()).morphInner(
      cookedEl,
      `<div>${data.html}</div>`,
      MORPH_OPTIONS
    );
  });
});
