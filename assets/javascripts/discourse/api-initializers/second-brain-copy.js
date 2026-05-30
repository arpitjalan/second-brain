import { apiInitializer } from "discourse/lib/api";
import { iconHTML } from "discourse/lib/icon-library";

// One-tap "Copy" on every stan answer. Copies the clean answer text, stripping
// the collapsible tool-call block (and any embedded widget) so only the actual
// answer lands on the clipboard.
export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  const botUsername = (
    siteSettings?.second_brain_bot_username || "stan"
  ).toLowerCase();

  api.decorateCookedElement(
    (element, helper) => {
      const post = helper?.model ?? helper?.getModel?.();
      if (!post) {
        return;
      }
      if ((post.username || "").toLowerCase() !== botUsername) {
        return;
      }
      if (element.querySelector(":scope > .sb-copy")) {
        return; // already decorated
      }

      const button = document.createElement("button");
      button.type = "button";
      button.className = "sb-copy";
      button.title = "Copy answer";
      button.setAttribute("aria-label", "Copy answer");
      button.innerHTML = iconHTML("copy");

      button.addEventListener("click", async () => {
        const clone = element.cloneNode(true);
        clone
          .querySelectorAll("details, .sb-copy, .sb-widget-card, .sb-thinking")
          .forEach((n) => n.remove());
        const text = clone.innerText.trim();
        if (!text) {
          return;
        }
        try {
          await navigator.clipboard.writeText(text);
          button.innerHTML = iconHTML("check");
          button.classList.add("sb-copy--done");
          setTimeout(() => {
            button.innerHTML = iconHTML("copy");
            button.classList.remove("sb-copy--done");
          }, 1500);
        } catch {
          // clipboard unavailable (e.g. insecure context) — no-op
        }
      });

      element.classList.add("sb-has-copy");
      element.appendChild(button);
    },
    { id: "second-brain-copy", onlyStream: true }
  );
});
