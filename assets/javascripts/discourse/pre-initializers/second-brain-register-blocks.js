import { withPluginApi } from "discourse/lib/plugin-api";
import CaptureBlock from "../blocks/capture";
import RecentNotesBlock from "../blocks/recent-notes";

// Block components must be registered before core's "freeze-block-registry"
// initializer freezes the registry. Pre-initializers are application
// initializers, which run before all instance initializers (freeze-block-registry
// among them) — so this is the right place. The matching layout is configured
// later in api-initializers/second-brain-homepage.js.
export default {
  name: "second-brain-register-blocks",

  initialize() {
    withPluginApi((api) => {
      api.registerBlock(CaptureBlock);
      api.registerBlock(RecentNotesBlock);
    });
  },
};
