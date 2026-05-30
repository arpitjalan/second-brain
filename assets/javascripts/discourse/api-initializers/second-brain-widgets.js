import { apiInitializer } from "discourse/lib/api";

// Embed term-llm widgets inline. The bot's reply links to our same-origin proxy
// path (/second-brain/widgets/<name>/), which forwards to term-llm with the
// Bearer token. We find those links in cooked posts and drop an iframe next to
// them — in the DOM (not the cooked HTML), so the sanitizer doesn't strip it.
const PROXY_WIDGETS = "/second-brain/widgets/";

export default apiInitializer((api) => {
  api.decorateCookedElement(
    (element) => {
      element
        .querySelectorAll(`a[href*="${PROXY_WIDGETS}"]`)
        .forEach((link) => {
          if (link.dataset.sbWidget) {
            return;
          }
          link.dataset.sbWidget = "1";

          const frame = document.createElement("iframe");
          frame.src = link.href;
          frame.className = "sb-widget-frame";
          frame.loading = "lazy";
          frame.setAttribute(
            "sandbox",
            "allow-scripts allow-same-origin allow-forms allow-popups"
          );
          link.insertAdjacentElement("afterend", frame);
        });
    },
    { id: "second-brain-widgets" }
  );
});
