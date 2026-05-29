import { apiInitializer } from "discourse/lib/api";

// Layouts are configured AFTER the block/outlet registries are frozen, so this
// runs as a normal api-initializer (not before freeze-block-registry).
//
// The `custom_homepage_enabled` plugin modifier routes the homepage to the
// `homepage-blocks` outlet; here we declare what fills it. Block names are
// namespaced ("plugin:name") as required for plugin-registered blocks.
export default apiInitializer((api) => {
  api.renderBlocks("homepage-blocks", [
    { block: "second-brain:capture" },
    { block: "second-brain:recent-notes", args: { limit: 12 } },
  ]);
});
