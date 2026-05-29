import { withPluginApi } from "discourse/lib/plugin-api";
import CaptureBlock from "../blocks/capture";
import RecentNotesBlock from "../blocks/recent-notes";

// Block components must be registered before core's "freeze-block-registry"
// freezes the registry. That freeze is an application initializer, so this must
// be a pre-initializer (also application-phase) AND declare `before:` to be
// ordered ahead of it — the directory alone isn't enough. The matching layout
// is configured later in api-initializers/second-brain-homepage.js.
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
