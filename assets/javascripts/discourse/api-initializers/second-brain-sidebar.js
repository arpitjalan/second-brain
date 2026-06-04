import { apiInitializer } from "discourse/lib/api";

// Add a "Search chats" link to the sidebar's Community section, pointing at the
// dedicated search page. Keeps search always reachable without crowding the
// homepage. (The route itself bounces anonymous visitors home.)
export default apiInitializer((api) => {
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
