# frozen_string_literal: true

# Keep the existing implementations so older deployment commands remain valid.
namespace :discourse_steward do
  desc "Seed Discourse Steward forum defaults"
  task setup: "second_brain:setup"

  desc "Make the forum private for family use"
  task lockdown: "second_brain:lockdown"

  desc "Provision the family agent"
  task set_family_agent: "second_brain:set_family_agent"

  desc "Register or update a personal agent"
  task add_agent: "second_brain:add_agent"

  desc "List registered agents (tokens masked)"
  task list_agents: "second_brain:list_agents"

  desc "Remove a personal agent's registry row"
  task remove_agent: "second_brain:remove_agent"
end
