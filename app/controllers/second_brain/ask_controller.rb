# frozen_string_literal: true

module ::SecondBrain
  class AskController < ::ApplicationController
    requires_login

    def create
      question = params[:question].to_s.strip
      raise Discourse::InvalidParameters, :question if question.blank?

      answer = TermLlmClient.new.ask(question)
      render json: { answer: answer }
    rescue TermLlmClient::NotConfigured
      render_json_error I18n.t("second_brain.errors.not_configured"), status: 422
    rescue TermLlmClient::Error => e
      render_json_error I18n.t("second_brain.errors.request_failed", message: e.message),
                        status: 502
    end
  end
end
