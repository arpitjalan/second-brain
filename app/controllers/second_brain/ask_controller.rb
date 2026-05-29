# frozen_string_literal: true

module ::SecondBrain
  class AskController < ::ApplicationController
    requires_login

    ROLES = %w[user assistant system].freeze

    def create
      messages = normalize_messages(params[:messages])
      raise Discourse::InvalidParameters, :messages if messages.empty?

      answer = TermLlmClient.new.complete(messages)
      render json: { answer: answer }
    rescue TermLlmClient::NotConfigured
      render_json_error I18n.t("second_brain.errors.not_configured"), status: 422
    rescue TermLlmClient::Error => e
      render_json_error I18n.t("second_brain.errors.request_failed", message: e.message),
                        status: 502
    end

    private

    def normalize_messages(raw)
      Array(raw).filter_map do |m|
        role = m[:role].to_s
        content = m[:content].to_s.strip
        next if content.blank? || !ROLES.include?(role)

        { role: role, content: content }
      end
    end
  end
end
