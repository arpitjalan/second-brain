# Second Brain — theme

Owns the homepage. Sets the `custom_homepage` modifier (about.json) so the
homepage routes to the `homepage-blocks` Blocks outlet, then fills it with two
blocks.

```
about.json                                   custom_homepage modifier + metadata
common/common.scss                           Notion-calm styling (BEM, sb-*)
javascripts/discourse/
  blocks/capture.gjs                          @block("second-brain-capture")
  blocks/recent-notes.gjs                     @block("second-brain-recent-notes")
  initializers/second-brain-register-blocks.js  registerBlock — BEFORE freeze
  api-initializers/second-brain-homepage.js      renderBlocks — AFTER freeze
```

## How the Blocks wiring works

- **Register before freeze:** custom blocks must be registered before core's
  `freeze-block-registry` initializer; our registration initializer declares
  `before: "freeze-block-registry"`.
- **Lay out after freeze:** `api.renderBlocks("homepage-blocks", [...])` runs in
  a normal api-initializer (layouts are configured after the registry freezes).

## Caveats / follow-ups

- The Blocks API is `@experimental` in core — it may change.
- Display strings are currently hard-coded; make them translatable via
  `themePrefix` + `locales/en.yml` once the wiring is verified.
- `recent-notes` shows the latest topics; once notes have their own
  category/structure, scope the query accordingly.
