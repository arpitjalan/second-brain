# frozen_string_literal: true

# Registry of per-user (and the family) agents. Each row maps a Discourse bot
# user to the term-llm endpoint/token that backs it. The family/default agent
# needs no row — Agent.family falls back to the global site settings — so an
# empty table behaves exactly like the single-agent setup.
class CreateSecondBrainAgents < ActiveRecord::Migration[7.2]
  def change
    create_table :second_brain_agents do |t|
      t.integer :bot_user_id, null: false
      t.string :term_llm_url, null: false, default: ""
      t.string :term_llm_token, null: false, default: "" # server-side secret
      t.string :agent_name
      t.string :model
      t.integer :owner_user_id # null = shared/family; set = personal
      t.string :forum_role, null: false, default: "tl4"
      t.timestamps
    end

    add_index :second_brain_agents, :bot_user_id, unique: true
    add_index :second_brain_agents, :owner_user_id
  end
end
