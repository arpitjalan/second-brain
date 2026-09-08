import { i18n } from "discourse-i18n";

export default <template>
  {{#if @post.second_brain_runtime.model}}
    <span
      class="sb-reply-runtime"
      title={{i18n "second_brain.runtime.reported"}}
    >
      {{@post.second_brain_runtime.model}}
      {{#if @post.second_brain_runtime.reasoning_effort}}
        ·
        {{@post.second_brain_runtime.reasoning_effort}}
      {{/if}}
    </span>
  {{/if}}
</template>
