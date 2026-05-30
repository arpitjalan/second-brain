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

    # forum_role is advisory metadata for this phase — a personal agent's actual
    # privilege (TL4, non-admin) is set on its bot User at provisioning time, not
    # enforced from this column.
  end
end
