import { apiInitializer } from "discourse/lib/api";

// Layouts are configured AFTER the block/outlet registries are frozen, so this
// runs as a normal api-initializer (not before freeze-block-registry).
//
// The `custom_homepage` modifier in about.json routes the homepage to the
// `homepage-blocks` outlet; here we declare what fills it.
export default apiInitializer((api) => {
  api.renderBlocks("homepage-blocks", [
    { block: "second-brain-capture" },
    { block: "second-brain-recent-notes", args: { limit: 12 } },
  ]);
});
