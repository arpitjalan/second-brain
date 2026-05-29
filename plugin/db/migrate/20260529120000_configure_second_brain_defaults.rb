# frozen_string_literal: true

# Runs once on install/upgrade (during db:migrate) to establish the calm
# "second brain" layout, so the admin never has to flip these by hand.
#
# Every write uses `ON CONFLICT (name) DO NOTHING`: the value is only seeded
# when the setting has no row yet (i.e. it's still at its factory default).
# That means a fresh install gets the full experience for free, while an
# existing site that already customized any of these keeps its own choice.
class ConfigureSecondBrainDefaults < ActiveRecord::Migration[7.2]
  # data_type codes (lib/site_settings/type_supervisor.rb): bool = 5, list = 8
  def up
    seed_setting("enable_welcome_banner", 5, "f") # hide the welcome banner + its search
    seed_setting("top_menu", 8, "latest")         # collapse the Latest/Hot/Categories pills
    seed_setting("enable_chat", 5, "f")           # drop the CHANNELS sidebar section

    # post_menu: same default, minus the "like" button. Read the live default
    # so we don't hard-code a list that could drift between Discourse versions.
    unless setting_exists?("post_menu")
      without_like = SiteSetting.post_menu.to_s.split("|").reject { |i| i == "like" }.join("|")
      seed_setting("post_menu", 8, without_like)
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def setting_exists?(name)
    DB.query_single("SELECT 1 FROM site_settings WHERE name = :name", name:).first
  end

  def seed_setting(name, data_type, value)
    DB.exec(<<~SQL, name:, data_type:, value:)
      INSERT INTO site_settings(name, data_type, value, created_at, updated_at)
      VALUES(:name, :data_type, :value, NOW(), NOW())
      ON CONFLICT (name) DO NOTHING
    SQL
  end
end
