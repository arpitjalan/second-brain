import Launcher from "../../components/launcher";

// The homepage. `register_modifier(:custom_homepage_enabled)` in plugin.rb
// routes the homepage to discovery/custom, whose `custom-homepage` plugin
// outlet renders this connector. A chat is a PM with the bot, so the homepage
// is a launcher; the conversation lives in Discourse's native message view.
<template>
  <div class="sb-home">
    <Launcher />
  </div>
</template>
