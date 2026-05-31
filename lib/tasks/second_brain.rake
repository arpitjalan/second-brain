# frozen_string_literal: true

# Plugin rake tasks (Discourse auto-loads this via Rake.add_rakelib):
#
# Invocation: a dev checkout uses `bin/rake …`; INSIDE a standard Discourse Docker
# container (./launcher enter app, cd /var/www/discourse) use plain `rake …` —
# `bin/rake` fails there. Examples below use `rake`.
#
#   Forum setup (site settings):
#     rake second_brain:setup      # seed the calm "second brain" forum layout
#     rake second_brain:lockdown   # make the forum private (before real family use)
#
#   Family agent — endpoint + the bot's forum-action key (writes global settings):
#     SB_URL=https://host/chat SB_TOKEN=… [SB_MODEL=gpt-5.5] [SB_NEW_KEY=1] rake second_brain:set_family_agent
#
#   Per-user (personal) agents — the PROD provisioning path (local dev uses
#   scripts/setup-local-dev.sh --owner, which also spins up the docker container):
#     SB_BOT=jarvis SB_OWNER=arpit SB_URL=https://host/chat SB_TOKEN=… \
#       [SB_MODEL=gpt-5.5] [SB_NEW_KEY=1] rake second_brain:add_agent
#     rake second_brain:list_agents
#     SB_BOT=jarvis [SB_DEACTIVATE=1] rake second_brain:remove_agent
#
# Both add_agent and set_family_agent print the term-llm-host env (DISCOURSE_URL /
# BOT_USERNAME / API_KEY) and point at term-llm/README.md for the bot-side setup.
#
# The setup/lockdown tasks write *core / other-plugin* site settings (not our own
# plugin settings, which default via config/settings.yml), so they can't be a
# settings.yml default — and seeding settings isn't a schema change, so it doesn't
# belong in db/migrate. The agent tasks manage the second_brain_agents registry
# (one row per personal agent; the family agent uses the global settings).

# --- helpers (top-level so the task blocks can call them) --------------------

# Find a user by username or email (owner lookup).
def sb_user(name)
  User.find_by(username_lower: name.to_s.downcase) || User.find_by_email(name.to_s)
end

# The registry table is created by a migration; bail clearly if it's absent.
def sb_require_registry!
  return if SecondBrain::AgentRecord.table_exists?
  abort "The second_brain_agents table is missing — run migrations first: bin/rake db:migrate"
end

# Show enough of a secret to identify it, never the whole thing.
def sb_mask(secret)
  s = secret.to_s
  s.empty? ? "(none)" : "#{s[0, 6]}…(len #{s.length})"
end

# Print the forum-action creds (term-llm -> Discourse) + where to put them. The
# bot's Discourse API key + bot username + the site URL go on the bot's term-llm
# host, alongside the `discourse` skill — full steps in term-llm/README.md.
def sb_print_termllm_host(bot, fresh_key)
  puts
  puts "  Forum actions (term-llm → Discourse): set these on #{bot.username}'s term-llm"
  puts "  host and install the `discourse` skill there. Full steps: term-llm/README.md"
  puts "    DISCOURSE_URL=#{Discourse.base_url}"
  puts "    DISCOURSE_BOT_USERNAME=#{bot.username}"
  if fresh_key
    puts "    DISCOURSE_API_KEY=#{fresh_key}"
    puts "  ↑ shown ONCE — copy it now (Discourse can't re-display it)."
  else
    puts "    DISCOURSE_API_KEY=<kept existing key; pass SB_NEW_KEY=1 to rotate>"
  end
end

# Mint a fresh Discourse API key for a bot when it has none (or SB_NEW_KEY is set);
# else nil (Discourse can't re-display an existing key's secret).
def sb_ensure_api_key(bot, label)
  has_key = ApiKey.where(user_id: bot.id, revoked_at: nil).exists?
  return nil if has_key && ENV["SB_NEW_KEY"].blank?
  ApiKey.create!(description: "second-brain #{label} #{bot.username}", created_by: Discourse.system_user, user: bot).key
end

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

  desc "Provision the family agent: term-llm endpoint + the bot's forum-action key (ENV: SB_URL SB_TOKEN; optional SB_MODEL SB_NEW_KEY)"
  task set_family_agent: :environment do
    url = ENV["SB_URL"].to_s.strip
    token = ENV["SB_TOKEN"].to_s.strip

    missing = { "SB_URL" => url, "SB_TOKEN" => token }.select { |_, v| v.empty? }.keys
    if missing.any?
      abort "Missing #{missing.join(", ")}.\n" \
              "Usage: SB_URL=https://host/chat SB_TOKEN=… [SB_MODEL=gpt-5.5] [SB_NEW_KEY=1] " \
              "rake second_brain:set_family_agent"
    end

    # 1. Chat direction (Discourse → term-llm): the global settings.
    changes = {
      "second_brain_term_llm_url" => url,
      "second_brain_term_llm_api_key" => token,
    }
    # Only touch the model when SB_MODEL is given (passing it empty clears it = use
    # term-llm's default); omitting SB_MODEL leaves the current model untouched.
    changes["second_brain_term_llm_model"] = ENV["SB_MODEL"].to_s.strip if ENV.key?("SB_MODEL")

    changes.each do |name, value|
      secret = name.end_with?("api_key")
      was = SiteSetting.get(name)
      SiteSetting.set(name, value)
      puts "  #{name}: #{secret ? sb_mask(was) : was.presence || "(unset)"} -> #{secret ? sb_mask(value) : value.presence || "(default)"}"
    end

    # 2. Forum-action direction (term-llm → Discourse): the family bot is an admin
    #    with its own Discourse API key, and forum actions are enabled.
    bot = SecondBrain::Bot.user # find/create the bot named second_brain_bot_username
    bot.update!(admin: true) unless bot.admin?
    SiteSetting.second_brain_forum_actions_enabled = true
    fresh_key = sb_ensure_api_key(bot, "family agent")

    puts
    puts "✓ Family agent '#{bot.username}' → #{url} (admin; forum actions on)."
    sb_print_termllm_host(bot, fresh_key)
  end

  desc "Register/update a personal agent (ENV: SB_BOT SB_OWNER SB_URL SB_TOKEN; optional SB_MODEL SB_NEW_KEY)"
  task add_agent: :environment do
    sb_require_registry!

    bot_name = ENV["SB_BOT"].to_s.strip
    owner_name = ENV["SB_OWNER"].to_s.strip
    url = ENV["SB_URL"].to_s.strip
    token = ENV["SB_TOKEN"].to_s.strip
    model = ENV["SB_MODEL"].to_s.strip

    missing = { "SB_BOT" => bot_name, "SB_OWNER" => owner_name, "SB_URL" => url, "SB_TOKEN" => token }
    missing = missing.select { |_, v| v.empty? }.keys
    if missing.any?
      abort "Missing #{missing.join(", ")}.\n" \
              "Usage: SB_BOT=jarvis SB_OWNER=arpit SB_URL=https://host/chat SB_TOKEN=… " \
              "[SB_MODEL=gpt-5.5] [SB_NEW_KEY=1] rake second_brain:add_agent"
    end

    owner = sb_user(owner_name)
    abort "Owner '#{owner_name}' not found (username or email)." if owner.nil?

    # The bot User: TL4, non-admin, locked so it sticks. Mirrors setup-local-dev.sh.
    existing = User.find_by(username_lower: bot_name.downcase)
    suggested = UserNameSuggester.suggest(bot_name)
    if existing.nil? && suggested.downcase != bot_name.downcase
      abort "'#{bot_name}' isn't a usable Discourse username (reserved/invalid — Discourse " \
              "would rename it to '#{suggested}'). Pick a different bot username."
    end
    bot =
      existing ||
        User.create!(
          username: suggested,
          name: bot_name.titleize,
          email: "#{bot_name.downcase}@bot.second-brain.invalid",
          password: SecureRandom.hex(32),
          active: true,
          approved: true,
          trust_level: TrustLevel[4],
        )
    if bot.id == SecondBrain::Bot.user.id
      abort "'#{bot.username}' is the FAMILY bot (second_brain_bot_username) — it's configured " \
              "via global settings, not the registry. Use a different bot username for a personal agent."
    end
    bot.update!(admin: false, trust_level: TrustLevel[4], manual_locked_trust_level: TrustLevel[4])

    # API key for forum actions (term-llm -> Discourse).
    fresh_key = sb_ensure_api_key(bot, "agent")

    # The registry row (Discourse -> term-llm).
    row = SecondBrain::AgentRecord.find_or_initialize_by(bot_user_id: bot.id)
    created = row.new_record?
    if !created && row.owner_user_id != owner.id
      puts "  note: reassigning '#{bot.username}' from owner_id=#{row.owner_user_id} to #{owner.username}."
    end
    row.update!(
      term_llm_url: url,
      term_llm_token: token,
      agent_name: bot.username,
      model: model.presence,
      owner_user_id: owner.id,
      forum_role: "tl4",
    )
    SiteSetting.second_brain_forum_actions_enabled = true

    puts "✓ Personal agent '#{bot.username}' #{created ? "registered" : "updated"} — owner #{owner.username}, TL4."
    puts "  Chat (Discourse → term-llm):  #{url}#{model.present? ? "   model=#{model}" : ""}"
    sb_print_termllm_host(bot, fresh_key)
    puts
    puts "  Live immediately — #{owner.username} sees it in the launcher switcher (no restart needed)."
  end

  desc "List the registered agents (family + personal); tokens masked"
  task list_agents: :environment do
    fam = SecondBrain::Agent.family
    puts "FAMILY (global settings):"
    puts "  bot=#{fam.user&.username || "(unset)"}  url=#{fam.url.presence || "(unset)"}  " \
           "token=#{sb_mask(fam.token)}  model=#{fam.model || "(term-llm default)"}"
    puts

    unless SecondBrain::AgentRecord.table_exists?
      puts "PERSONAL: (registry table not migrated)"
      next
    end
    rows = SecondBrain::AgentRecord.order(:id)
    if rows.empty?
      puts "PERSONAL: (none)"
    else
      puts "PERSONAL (#{rows.size}):"
      rows.each do |r|
        bot = User.find_by(id: r.bot_user_id)
        owner = User.find_by(id: r.owner_user_id)
        puts "  bot=#{bot&.username || "?(id #{r.bot_user_id})"}  owner=#{owner&.username || "(shared)"}  " \
               "url=#{r.term_llm_url}  token=#{sb_mask(r.term_llm_token)}  " \
               "model=#{r.model.presence || "(default)"}  role=#{r.forum_role}"
      end
    end
  end

  desc "Remove a personal agent's registry row (ENV: SB_BOT; optional SB_DEACTIVATE to disable the bot user)"
  task remove_agent: :environment do
    sb_require_registry!
    bot_name = ENV["SB_BOT"].to_s.strip
    abort "Missing SB_BOT.\nUsage: SB_BOT=jarvis [SB_DEACTIVATE=1] rake second_brain:remove_agent" if bot_name.empty?

    bot = User.find_by(username_lower: bot_name.downcase)
    abort "No Discourse user '#{bot_name}'." if bot.nil?
    row = SecondBrain::AgentRecord.find_by(bot_user_id: bot.id)
    abort "No personal-agent registry row for '#{bot.username}' — nothing to remove." if row.nil?

    owner = User.find_by(id: row.owner_user_id)
    row.destroy!
    puts "✓ Removed personal agent '#{bot.username}' (was owned by #{owner&.username || "?"}) from the registry."
    if ENV["SB_DEACTIVATE"].present?
      bot.update!(active: false)
      puts "  Deactivated the bot user '#{bot.username}'."
    else
      puts "  The bot user '#{bot.username}' still exists — pass SB_DEACTIVATE=1 to disable it. " \
             "Revoke its API keys in Admin → API if it should no longer act on the forum."
    end
  end
end
