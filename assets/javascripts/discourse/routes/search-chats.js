import { service } from "@ember/service";
import DiscourseRoute from "discourse/routes/discourse";

// The "search your chats" page. Personal, so anonymous visitors are bounced home
// (the scoped search endpoint requires login anyway).
export default class SearchChatsRoute extends DiscourseRoute {
  @service currentUser;
  @service router;

  beforeModel() {
    if (!this.currentUser) {
      this.router.replaceWith("discovery.latest");
    }
  }

  titleToken() {
    return "Search your AI chats";
  }
}
