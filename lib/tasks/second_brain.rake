# frozen_string_literal: true

# Plugin rake tasks:
#
#     bin/rake second_brain:setup      # seed the calm "second brain" forum layout
#     bin/rake second_brain:lockdown   # make the forum private (before real family use)
#
# These are *core / other-plugin* site settings (not our own plugin settings,
# which default via config/settings.yml) — so they can't be set with a
# settings.yml default; they have to be written into the site_settings table.
# Seeding settings isn't a schema change, so it doesn't belong in db/migrate and
# shouldn't ride db:migrate — hence a one-shot rake task instead.
#
# Idempotent: each setting is only seeded when it has no row yet (i.e. it's still
# at its factory default), so an admin who already customized one keeps their
# choice, and re-running is safe. Run it once after installing the plugin
# (scripts/setup-local-dev.sh runs it for you in local dev).
#
# Discourse auto-loads this file via Rake.add_rakelib (lib/plugin/instance.rb).

namespace :second_brain do
  desc "Seed the calm second-brain forum defaults (idempotent; only touches factory-default settings)"
  task setup: :environment do
    # data_type codes (lib/site_settings/type_supervisor.rb): bool = 5, list = 8.
    seeds = [
      ["enable_welcome_banner", 5, "f"],       # hide the welcome banner + its search
      ["top_menu", 8, "latest"],               # collapse the Latest/Hot/Categories pills
      ["enable_chat", 5, "f"],                  # drop the CHANNELS sidebar section
      ["discourse_reactions_enabled", 5, "t"], # emoji reactions (orphan row is harmless if the plugin isn't loaded)
    ]
    # NOTE: we deliberately leave `post_menu` at its factory default (which keeps
    # the Like button). The two migrations this replaced first removed "like" then
    # added it back — a net no-op — so there's nothing to seed here.

    seeded = []
    seeds.each do |name, data_type, value|
      next if DB.query_single("SELECT 1 FROM site_settings WHERE name = :name", name: name).first
      DB.exec(<<~SQL, name: name, data_type: data_type, value: value)
        INSERT INTO site_settings(name, data_type, value, created_at, updated_at)
        VALUES(:name, :data_type, :value, NOW(), NOW())
        ON CONFLICT (name) DO NOTHING
      SQL
      seeded << name
    end

    if seeded.any?
      SiteSetting.refresh! # drop the cache so the running app sees the new values
      puts "second_brain:setup — seeded: #{seeded.join(", ")}"
    else
      puts "second_brain:setup — nothing to do (all already set)"
    end
  end

  # Unlike :setup (which only seeds factory-default settings), this deliberately
  # ASSERTS a private posture — that's the whole point — so run it knowingly,
  # before inviting real family members. Idempotent + reversible (it prints the
  # before -> after for each so you can flip any back).
  desc "Make the forum private for family use: login required, invite-only, no search indexing"
  task lockdown: :environment do
    {
      "login_required" => true,             # must sign in to see anything
      "invite_only" => true,                # new accounts only via an invite
      "allow_index_in_robots_txt" => false, # ask search engines not to index us
    }.each do |name, value|
      was = SiteSetting.get(name)
      SiteSetting.set(name, value)
      puts "  #{name}: #{was} -> #{value}"
    end
    puts "second_brain:lockdown — forum is now private (login required, invite-only, noindex)."
  end
end
