# Renaming to Discourse Steward

The plugin is now named `discourse-steward` (Discourse Steward). Its Discourse
installation directory and frontend assets use that name. No database migration
or agent reconfiguration is required.

## Updating an existing installation

Update the existing checkout to this version and rename its entry in Discourse's
`plugins` directory from `second-brain` to `discourse-steward`. For a symlinked dev
checkout, rename only the symlink; its target checkout can keep its existing name:

```bash
cd ~/discourse/plugins
mv second-brain discourse-steward
```

Install only one copy. Keeping both plugin entries would load the same code and
migrations twice. Restart Discourse and its background workers after updating;
production installations should rebuild through their usual deployment process.
Refresh existing browser tabs to load the renamed assets.

The source GitHub repository and its raw download URLs remain at
`arpitjalan/second-brain` until the repository itself is renamed. This change does
not move the Git remote or the developer's checkout directory. Setup scripts find
the checkout containing them and still accept `PLUGIN_DIR` overrides. Standalone
scripts also recognize the old default checkout location.

## Compatibility identifiers

These identifiers deliberately keep their existing spelling:

- `second_brain_*` site settings, including the enable switch and credentials.
- The `second_brain_agents` table and existing migration versions.
- Post/topic custom fields, bot account identity, and `@bot.second-brain.invalid`
  addresses used to recognize provisioned bots.
- `SecondBrain` Ruby classes and queued `Jobs::SecondBrain*` jobs.
- `/second-brain/*` HTTP routes, widget URLs embedded in existing posts,
  MessageBus channels, and widget bridge messages.
- Redis keys, locks, rate limits, term-llm session IDs, browser preferences,
  CSS classes, and locale keys.
- Managed SSH configuration markers and other provisioning identifiers.

Changing these would require a separate compatibility migration. They are not
user-facing product branding. Keeping them avoids losing settings, breaking saved
widgets, duplicating agents, or orphaning a pending question or background job.

New commands use `rake discourse_steward:setup`, `:lockdown`, `:set_family_agent`,
`:add_agent`, `:list_agents`, and `:remove_agent`. Existing `second_brain:*`
commands and their output remain supported; the new tasks delegate to the same
implementations.

Run the regression suite from Discourse with:

```bash
bin/rspec plugins/discourse-steward/spec
```
