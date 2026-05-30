# frozen_string_literal: true

module ::SecondBrain
  # A registry row: the persisted half of an Agent (see lib/second_brain/agent.rb).
  # The family/default agent has no row (it falls back to the global settings);
  # personal agents each get one. `term_llm_token` is a server-side secret and is
  # never serialized to the client.
  class AgentRecord < ::ActiveRecord::Base
    self.table_name = "second_brain_agents"
  end
end
