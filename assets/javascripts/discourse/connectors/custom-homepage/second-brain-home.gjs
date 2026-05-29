import Chat from "../../components/chat";

// The homepage. `register_modifier(:custom_homepage_enabled)` in plugin.rb
// routes the homepage to discovery/custom, whose `custom-homepage` plugin
// outlet renders this connector. The homepage is the chat with term-llm.
<template>
  <div class="sb-home">
    <Chat />
  </div>
</template>
