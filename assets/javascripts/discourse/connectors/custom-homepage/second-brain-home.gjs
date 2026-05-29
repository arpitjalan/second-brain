import Capture from "../../components/capture";
import RecentNotes from "../../components/recent-notes";

// The homepage. `register_modifier(:custom_homepage_enabled)` in plugin.rb
// routes the homepage to discovery/custom, whose `custom-homepage` plugin
// outlet renders this connector. A plain component tree — no Blocks API.
<template>
  <div class="sb-home">
    <Capture />
    <RecentNotes @limit={{12}} />
  </div>
</template>
