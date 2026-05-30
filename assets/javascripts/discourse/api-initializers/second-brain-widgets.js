import { apiInitializer } from "discourse/lib/api";
import { iconHTML } from "discourse/lib/icon-library";

// Embed term-llm widgets inline as little "apps". The bot's reply links to our
// same-origin proxy path (/second-brain/widgets/<name>/), which forwards to
// term-llm with the Bearer token. We find those links in cooked posts and drop
// a framed widget card next to them — in the DOM (not the cooked HTML), so the
// sanitizer doesn't strip it.
const PROXY_WIDGETS = "/second-brain/widgets/";

// "/second-brain/widgets/hacker-news-top/" -> "Hacker News Top"
function widgetTitle(href) {
  try {
    const path = new URL(href, window.location.origin).pathname;
    const slug =
      (path.split(PROXY_WIDGETS)[1] || "").replace(/\/+$/, "").split("/")[0] ||
      "Widget";
    return decodeURIComponent(slug)
      .replace(/[-_]+/g, " ")
      .replace(/\b\w/g, (c) => c.toUpperCase());
  } catch {
    return "Widget";
  }
}

function shimmerEl() {
  const s = document.createElement("div");
  s.className = "sb-widget-card__shimmer";
  return s;
}

function iconButton(icon, label, onClick) {
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "sb-widget-card__btn";
  btn.title = label;
  btn.setAttribute("aria-label", label);
  btn.innerHTML = iconHTML(icon);
  btn.addEventListener("click", onClick);
  return btn;
}

function buildCard(href) {
  const card = document.createElement("div");
  card.className = "sb-widget-card";

  const frameWrap = document.createElement("div");
  frameWrap.className = "sb-widget-card__frame-wrap";

  const frame = document.createElement("iframe");
  frame.src = href;
  frame.className = "sb-widget-frame";
  frame.loading = "lazy";
  frame.setAttribute(
    "sandbox",
    "allow-scripts allow-same-origin allow-forms allow-popups"
  );
  // Drop any pending shimmer once the widget paints.
  frame.addEventListener("load", () => {
    frameWrap
      .querySelectorAll(".sb-widget-card__shimmer")
      .forEach((s) => s.remove());
  });

  const refresh = iconButton("arrows-rotate", "Refresh", () => {
    frameWrap.prepend(shimmerEl());
    const url = new URL(frame.src, window.location.origin);
    url.searchParams.set("_r", Date.now().toString()); // cache-bust
    frame.src = url.toString();
  });

  const openTab = document.createElement("a");
  openTab.className = "sb-widget-card__btn";
  openTab.href = href;
  openTab.target = "_blank";
  openTab.rel = "noopener";
  openTab.title = "Open in new tab";
  openTab.setAttribute("aria-label", "Open in new tab");
  openTab.innerHTML = iconHTML("up-right-from-square");

  const fullscreen = iconButton("expand", "Full screen", () => {
    if (document.fullscreenElement) {
      document.exitFullscreen?.();
    } else {
      card.requestFullscreen?.();
    }
  });

  const title = document.createElement("span");
  title.className = "sb-widget-card__title";
  title.textContent = widgetTitle(href);

  const actions = document.createElement("div");
  actions.className = "sb-widget-card__actions";
  actions.append(refresh, openTab, fullscreen);

  const bar = document.createElement("div");
  bar.className = "sb-widget-card__bar";
  bar.append(title, actions);

  frameWrap.append(shimmerEl(), frame);
  card.append(bar, frameWrap);
  return card;
}

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
          link.insertAdjacentElement("afterend", buildCard(link.href));
        });
    },
    { id: "second-brain-widgets" }
  );
});
