# frozen_string_literal: true

module ::SecondBrain
  # A registry row: the persisted half of an Agent (see lib/second_brain/agent.rb).
  # The family/default agent has no row (it falls back to the global settings);
  # personal agents each get one. `term_llm_token` is a server-side secret and is
  # never serialized to the client.
  class AgentRecord < ::ActiveRecord::Base
    self.table_name = "second_brain_agents"

    validates :bot_user_id, presence: true, uniqueness: true
    validates :forum_role, inclusion: { in: %w[admin tl4 none] }
    # A registry row IS a personal agent — it has no global-settings fallback, so a
    # blank endpoint/token would silently cross-wire the family credentials onto it
    # (or vice versa). Require both; the provisioning task always supplies them.
    validates :term_llm_url, :term_llm_token, presence: true

    # forum_role is advisory metadata for this phase — a personal agent's actual
    # privilege (TL4, non-admin) is set on its bot User at provisioning time, not
    # enforced from this column.
  end
end
