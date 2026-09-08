import { apiInitializer } from "discourse/lib/api";
import SbReplyRuntime from "../components/sb-reply-runtime";

export default apiInitializer((api) => {
  api.registerValueTransformer(
    "post-meta-data-infos",
    ({ value: dag, context: { metaDataInfoKeys } }) => {
      dag.add("second-brain-runtime", SbReplyRuntime, {
        before: metaDataInfoKeys.DATE,
      });
    }
  );
});
