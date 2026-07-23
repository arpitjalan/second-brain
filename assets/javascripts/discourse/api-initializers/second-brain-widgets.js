import { apiInitializer } from "discourse/lib/api";
import { iconHTML } from "discourse/lib/icon-library";

// Embed term-llm widgets inline as little "apps". The bot's reply links to our
// same-origin proxy path — family "/second-brain/widgets/<name>/" or a personal
// agent's "/second-brain/agent-widgets/<agent>/<name>/" — which forwards to that
// agent's term-llm with its Bearer token. We find those links in cooked posts and
// drop a framed widget card next to them — in the DOM (not the cooked HTML), so
// the sanitizer doesn't strip it.
const WIDGET_PREFIX_RE = /\/second-brain\/(?:agent-widgets\/[^/]+|widgets)\//;
// Anchored: the pathname must START with our proxy prefix — not merely contain it.
const WIDGET_PATH_RE = /^\/second-brain\/(?:agent-widgets\/[^/]+|widgets)\//;
const WIDGET_LINK_SELECTOR =
  'a[href*="/second-brain/widgets/"], a[href*="/second-brain/agent-widgets/"]';

// Return the same-origin widget-proxy path (pathname + query) to frame, or null if
// this link is not genuinely one of ours. The selector matches on a substring, so a
// link to another host that merely CONTAINS "/second-brain/widgets/" (anywhere in
// its path or query — e.g. https://evil.example/second-brain/widgets/login, or
// /latest?x=/second-brain/widgets/) would otherwise be framed as a trusted
// first-party widget under allow-scripts/allow-same-origin/allow-forms. Require the
// same origin AND a pathname that actually starts with our proxy prefix, and frame
// the resolved path — never the raw href (which could point off-origin).
function safeWidgetPath(link) {
  let url;
  try {
    url = new URL(link.getAttribute("href"), window.location.origin);
  } catch {
    return null;
  }
  if (url.origin !== window.location.origin) {
    return null;
  }
  if (!WIDGET_PATH_RE.test(url.pathname)) {
    return null;
  }
  return url.pathname + url.search;
}

// "/second-brain/widgets/hacker-news-top/" -> "Hacker News Top"
function widgetTitle(href) {
  try {
    const path = new URL(href, window.location.origin).pathname;
    const slug =
      (path.split(WIDGET_PREFIX_RE)[1] || "").replace(/\/+$/, "").split("/")[0] ||
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
  const clearShimmer = () => {
    frameWrap
      .querySelectorAll(".sb-widget-card__shimmer")
      .forEach((s) => s.remove());
  };
  // Never shimmer forever: if the frame hasn't loaded in 15s (term-llm down, bad
  // path), drop the shimmer and show a calm error. Refresh stays available.
  const armTimeout = () => {
    clearTimeout(frameWrap._sbTimeout);
    frameWrap._sbTimeout = setTimeout(() => {
      if (!frameWrap.querySelector(".sb-widget-card__shimmer")) {
        return;
      }
      clearShimmer();
      const note = document.createElement("div");
      note.className = "sb-widget-card__error";
      note.textContent = "Widget unavailable — try refreshing.";
      frameWrap.appendChild(note);
    }, 15000);
  };
  // Drop the shimmer once the widget paints.
  frame.addEventListener("load", () => {
    clearTimeout(frameWrap._sbTimeout);
    clearShimmer();
  });
  armTimeout();

  const refresh = iconButton("arrows-rotate", "Refresh", () => {
    frameWrap
      .querySelectorAll(".sb-widget-card__error")
      .forEach((n) => n.remove());
    frameWrap.prepend(shimmerEl());
    armTimeout();
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
        .querySelectorAll(WIDGET_LINK_SELECTOR)
        .forEach((link) => {
          if (link.dataset.sbWidget) {
            return;
          }
          const src = safeWidgetPath(link);
          if (!src) {
            return;
          }
          link.dataset.sbWidget = "1";
          link.insertAdjacentElement("afterend", buildCard(src));
        });
    },
    // onlyStream (like the copy/askuser decorators): widget cards belong in the
    // post stream, not the composer preview — where each debounced re-cook would
    // otherwise mount a fresh iframe and re-hit the authenticated proxy on every
    // keystroke near a widget link.
    { id: "second-brain-widgets", onlyStream: true }
  );
});
