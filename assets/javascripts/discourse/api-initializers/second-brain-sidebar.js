import { apiInitializer } from "discourse/lib/api";

// Add a "Search chats" link to the sidebar's Community section, pointing at the
// dedicated search page. Keeps search always reachable without crowding the
// homepage. (The route itself bounces anonymous visitors home.)
export default apiInitializer((api) => {
  // The page is personal (and bounces anon home), so don't show the link to
  // anonymous visitors — matches core's convention for user-only section links.
  if (!api.getCurrentUser()) {
    return;
  }
  api.addCommunitySectionLink((baseSectionLink) => {
    return class SearchChatsSectionLink extends baseSectionLink {
      name = "second-brain-search-chats";
      route = "search-chats";
      text = "Search AI chats";
      title = "Search your AI chats";
      defaultPrefixValue = "magnifying-glass";
    };
  });
});
