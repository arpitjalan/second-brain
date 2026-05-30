import { apiInitializer } from "discourse/lib/api";

// Embed term-llm widgets inline. The bot's reply links to an (absolutized)
// widget URL like https://brain.example.com/chat/widgets/dashboard/ ; we find
// those links in cooked posts and drop an iframe next to them. Done in the DOM
// (not the cooked HTML) so Discourse's sanitizer doesn't strip the iframe.
export default apiInitializer((api) => {
  const siteSettings = api.container.lookup("service:site-settings");
  const base = (siteSettings.second_brain_term_llm_url || "").replace(
    /\/+$/,
    ""
  );
  if (!base) {
    return;
  }

  const widgetPrefix = `${base}/widgets/`;

  api.decorateCookedElement(
    (element) => {
      element
        .querySelectorAll(`a[href^="${widgetPrefix}"]`)
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
