import Component from "@glimmer/component";
import { service } from "@ember/service";

// The homepage launcher. A chat is a Personal Message with the bot, so we just
// point at Discourse's native compose-new-message flow (private by default) and
// the user's message inbox. The conversation itself uses Discourse's PM UI.
export default class Launcher extends Component {
  @service siteSettings;
  @service currentUser;

  get botUsername() {
    return this.siteSettings.second_brain_bot_username || "stan";
  }

  get newChatUrl() {
    return `/new-message?username=${this.botUsername}`;
  }

  get myChatsUrl() {
    return `/u/${this.currentUser.username}/messages`;
  }

  <template>
    <div class="sb-launcher">
      <h1 class="sb-launcher__title">Your second brain</h1>
      <p class="sb-launcher__subtitle">
        Chat privately with {{this.botUsername}}. Every chat is private by default —
        make one public later if you want to share it.
      </p>

      {{#if this.currentUser}}
        <div class="sb-launcher__actions">
          <a class="btn btn-primary btn-large" href={{this.newChatUrl}}>
            Start a chat
          </a>
          <a class="btn btn-default btn-large" href={{this.myChatsUrl}}>
            Your chats
          </a>
        </div>
      {{/if}}
    </div>
  </template>
}
