import { withPluginApi } from "discourse/lib/plugin-api";
import CaptureBlock from "../blocks/capture";
import RecentNotesBlock from "../blocks/recent-notes";

// Blocks must be registered BEFORE the core "freeze-block-registry" initializer
// freezes the block registry, so we slot in ahead of it.
export default {
  name: "second-brain-register-blocks",
  before: "freeze-block-registry",

  initialize() {
    withPluginApi((api) => {
      api.registerBlock(CaptureBlock);
      api.registerBlock(RecentNotesBlock);
    });
  },
};
