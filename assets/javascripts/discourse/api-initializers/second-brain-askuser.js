import { ajax } from "discourse/lib/ajax";
import { popupAjaxError } from "discourse/lib/ajax-error";
import { apiInitializer } from "discourse/lib/api";
import { iconHTML } from "discourse/lib/icon-library";

// Renders term-llm's interactive ask_user prompt inline in stan's post. The
// server pauses the run and stores the question set on the post (serialized as
// `second_brain_askuser`); we paint a form, collect answers, and POST them to
// /second-brain/answer, which resumes the run and streams the continuation back
// into this same post. The form is built in the DOM (not cooked HTML), so the
// sanitizer never sees it.

function optionRow(question, name, opt, onChange) {
  const label = document.createElement("label");
  label.className = "sb-askuser__opt";
  const input = document.createElement("input");
  input.type = question.multi_select ? "checkbox" : "radio";
  input.name = name;
  input.value = opt.value;
  input.addEventListener("change", onChange);
  const text = document.createElement("span");
  text.className = "sb-askuser__opt-text";
  const strong = document.createElement("strong");
  strong.textContent = opt.label;
  text.appendChild(strong);
  if (opt.description) {
    const desc = document.createElement("small");
    desc.textContent = opt.description;
    text.appendChild(desc);
  }
  label.append(input, text);
  return { label, input };
}

function renderForm(container, post, data) {
  const questions = data.questions || [];
  const answers = questions.map(() => ({ selected: null, custom: "", list: [] }));

  const form = document.createElement("div");
  form.className = "sb-askuser__form";

  questions.forEach((question, qi) => {
    const card = document.createElement("div");
    card.className = "sb-askuser__q";

    if (questions.length > 1) {
      const step = document.createElement("span");
      step.className = "sb-askuser__step";
      step.textContent = `Question ${qi + 1} of ${questions.length}`;
      card.appendChild(step);
    }
    if (question.header) {
      const header = document.createElement("span");
      header.className = "sb-askuser__header";
      header.textContent = question.header;
      card.appendChild(header);
    }
    const text = document.createElement("p");
    text.className = "sb-askuser__question";
    text.textContent = question.question;
    card.appendChild(text);

    const name = `sbq-${post.id}-${qi}`;
    (question.options || []).forEach((opt) => {
      const { label } = optionRow(question, name, opt, () => {
        if (question.multi_select) {
          answers[qi].list = Array.from(
            card.querySelectorAll("input:checked")
          )
            .map((i) => i.value)
            .filter((v) => v !== "__other__");
        } else {
          answers[qi].selected = opt.label;
          const ta = card.querySelector(".sb-askuser__other");
          if (ta) {
            ta.hidden = true;
          }
        }
      });
      card.appendChild(label);
    });

    // Single-select questions also offer a free-text "Other" answer.
    if (!question.multi_select) {
      const textarea = document.createElement("textarea");
      textarea.className = "sb-askuser__other";
      textarea.rows = 1;
      textarea.placeholder = "Type your own answer…";
      textarea.hidden = true;
      textarea.addEventListener("input", () => {
        answers[qi].custom = textarea.value;
      });
      const { label } = optionRow(
        question,
        name,
        { label: "Other", value: "__other__" },
        () => {
          answers[qi].selected = "__other__";
          textarea.hidden = false;
          textarea.focus();
        }
      );
      card.append(label, textarea);
    }

    form.appendChild(card);
  });

  const error = document.createElement("div");
  error.className = "sb-askuser__error";
  const submit = document.createElement("button");
  submit.type = "button";
  submit.className = "btn btn-primary sb-askuser__submit";
  submit.textContent = "Send answers";

  const actions = document.createElement("div");
  actions.className = "sb-askuser__actions";
  actions.append(error, submit);
  form.appendChild(actions);

  submit.addEventListener("click", async () => {
    const payload = [];
    for (let i = 0; i < questions.length; i++) {
      const question = questions[i];
      const answer = answers[i];
      if (question.multi_select) {
        if (!answer.list.length) {
          error.textContent = "Please answer every question.";
          return;
        }
        payload.push({
          question_index: i,
          header: question.header || "",
          selected_list: answer.list,
          is_custom: false,
          is_multi_select: true,
        });
      } else if (answer.selected === "__other__") {
        if (!answer.custom.trim()) {
          error.textContent = "Please type your answer.";
          return;
        }
        payload.push({
          question_index: i,
          header: question.header || "",
          selected: answer.custom.trim(),
          is_custom: true,
          is_multi_select: false,
        });
      } else if (answer.selected) {
        payload.push({
          question_index: i,
          header: question.header || "",
          selected: answer.selected,
          is_custom: false,
          is_multi_select: false,
        });
      } else {
        error.textContent = "Please answer every question.";
        return;
      }
    }

    error.textContent = "";
    submit.disabled = true;
    submit.textContent = "Sending…";
    try {
      await ajax("/second-brain/answer", {
        type: "POST",
        contentType: "application/json",
        data: JSON.stringify({
          post_id: post.id,
          call_id: data.call_id,
          answers: payload,
        }),
      });
      // The server flips the status and refreshes the post, which re-renders
      // this as the answered summary; show an interim note meanwhile.
      form.replaceChildren();
      const sent = document.createElement("div");
      sent.className = "sb-askuser__sent";
      sent.textContent = "Answers sent — stan is continuing…";
      form.appendChild(sent);
    } catch (e) {
      submit.disabled = false;
      submit.textContent = "Send answers";
      if (e?.jqXHR?.status === 410) {
        error.textContent = "This question expired. Ask stan again to continue.";
      } else {
        popupAjaxError(e);
      }
    }
  });

  container.appendChild(form);
}

function renderSummary(container, data) {
  const chip = document.createElement("div");
  chip.className = "sb-askuser__summary";
  chip.innerHTML = iconHTML("check");
  const span = document.createElement("span");
  span.textContent = data.summary
    ? `You answered — ${data.summary}`
    : "Answered";
  chip.appendChild(span);
  container.appendChild(chip);
}

function renderExpired(container) {
  const note = document.createElement("div");
  note.className = "sb-askuser__expired";
  note.textContent = "This question expired. Ask stan again to continue.";
  container.appendChild(note);
}

export default apiInitializer((api) => {
  api.decorateCookedElement(
    (element, helper) => {
      const post = helper?.model ?? helper?.getModel?.();
      const data = post?.second_brain_askuser;
      if (!data) {
        return;
      }
      // Re-render only when the status changes (pending → answered → done).
      if (element.dataset.sbAskStatus === data.status) {
        return;
      }
      element
        .querySelectorAll(":scope > .sb-askuser")
        .forEach((n) => n.remove());
      element.dataset.sbAskStatus = data.status;

      const container = document.createElement("div");
      container.className = "sb-askuser";
      if (data.status === "pending") {
        renderForm(container, post, data);
      } else if (data.status === "expired") {
        renderExpired(container);
      } else {
        renderSummary(container, data);
      }
      element.appendChild(container);
    },
    { id: "second-brain-askuser", onlyStream: true }
  );
});
