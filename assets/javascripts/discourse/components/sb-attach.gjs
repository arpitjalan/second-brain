import Component from "@glimmer/component";
import { action } from "@ember/object";
import { getOwner } from "@ember/owner";
import didInsert from "@ember/render-modifiers/modifiers/did-insert";
import UppyUpload from "discourse/lib/uppy/uppy-upload";
import DButton from "discourse/ui-kit/d-button";

// Attach button for the chat composers (homepage launcher + inline reply box).
// Uploads files through Discourse's normal pipeline; each finished upload is
// handed to the parent via @onAdd. The parent turns them into markdown
// (getUploadMarkdown) and appends to the message it sends, so PostCreator links
// the upload:// refs and the file is really attached to the chat.
export default class SbAttach extends Component {
  uppyUpload = new UppyUpload(getOwner(this), {
    id: "second-brain-attach",
    type: "composer",
    uploadDone: (upload) => this.args.onAdd?.(upload),
  });

  setupInput = (el) => this.uppyUpload.setup(el);

  @action
  openPicker() {
    this.uppyUpload.openPicker();
  }

  <template>
    <span class="sb-attach">
      <input type="file" multiple hidden {{didInsert this.setupInput}} />
      <DButton
        @action={{this.openPicker}}
        @icon="paperclip"
        @translatedTitle="Attach files"
        @disabled={{@disabled}}
        class="sb-attach__btn btn-flat"
      />
      {{#if this.uppyUpload.uploading}}
        <span class="sb-attach__status">Uploading…</span>
      {{/if}}
    </span>
  </template>
}
