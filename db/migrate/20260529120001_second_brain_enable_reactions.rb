# frozen_string_literal: true

# Families enjoy likes and reactions — re-enable them. The earlier defaults
# migration removed the Like button; this restores it and turns on emoji
# reactions (discourse-reactions).
class SecondBrainEnableReactions < ActiveRecord::Migration[7.2]
  def up
    restore_like_button
    enable_reactions
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  # Add "like" back to post_menu if our earlier migration dropped it.
  def restore_like_button
    value = DB.query_single("SELECT value FROM site_settings WHERE name = 'post_menu'").first
    return if value.nil? # not customized — the default already includes like

    items = value.split("|")
    return if items.include?("like")

    index = items.index("read")
    items.insert(index ? index + 1 : 0, "like")

    DB.exec(<<~SQL, value: items.join("|"))
      UPDATE site_settings SET value = :value, updated_at = NOW() WHERE name = 'post_menu'
    SQL
  end

  # Turn on emoji reactions if the plugin is around. data_type 5 = bool.
  # Harmless if discourse-reactions isn't loaded (orphan row, ignored).
  def enable_reactions
    DB.exec(<<~SQL)
      INSERT INTO site_settings(name, data_type, value, created_at, updated_at)
      VALUES('discourse_reactions_enabled', 5, 't', NOW(), NOW())
      ON CONFLICT (name) DO NOTHING
    SQL
  end
end
