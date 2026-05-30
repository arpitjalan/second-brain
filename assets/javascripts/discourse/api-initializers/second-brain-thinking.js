import { apiInitializer } from "discourse/lib/api";

// The generic "thinking" pill (when no specific tool is running) shouldn't sit on
// one word. The server marks those pills with .sb-thinking--cycle and lists the
// words in data-sb-words; here we rotate to a fresh one every 10 seconds. Tool
// verbs ("Running a command", "Searching the web") aren't marked, so they hold.
const CYCLE_MS = 10000;

export default apiInitializer(() => {
  setInterval(() => {
    document.querySelectorAll(".sb-thinking--cycle").forEach((pill) => {
      const label = pill.querySelector(".sb-thinking__label");
      const words = (pill.dataset.sbWords || "").split("|").filter(Boolean);
      if (!label || words.length < 2) {
        return;
      }
      let next = label.textContent;
      while (next === label.textContent) {
        next = words[Math.floor(Math.random() * words.length)];
      }
      label.textContent = next;
    });
  }, CYCLE_MS);
});
