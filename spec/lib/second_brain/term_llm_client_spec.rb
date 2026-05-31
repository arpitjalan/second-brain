# frozen_string_literal: true

require "rails_helper"

describe SecondBrain::TermLlmClient do
  before do
    SiteSetting.second_brain_term_llm_url = "http://termllm.test/chat"
    SiteSetting.second_brain_term_llm_api_key = "tok"
  end

  let(:client) { SecondBrain::Agent.family.client }

  describe "#stream_events (resume reconnect)" do
    it "returns the reconnected response_id even when the stream omits response.created" do
      # A reconnect's continuation does NOT re-emit `response.created`; the result
      # must still carry the id we reconnected to, or the next ask_user round loses
      # the run (resume! bails on a blank response_id → the post hangs).
      sse = +""
      sse << "id: 5\nevent: response.output_text.delta\ndata: {\"delta\":\"continued answer\"}\n\n"
      sse << "data: [DONE]\n\n"
      stub_request(:get, "http://termllm.test/chat/v1/responses/resp_abc/events?after=2").to_return(
        status: 200,
        body: sse,
        headers: { "Content-Type" => "text/event-stream" },
      )

      result = client.stream_events(response_id: "resp_abc", after: 2)

      expect(result[:response_id]).to eq("resp_abc")
      expect(result[:text]).to eq("continued answer")
      expect(result[:last_seq]).to eq(5)
    end

    it "still prefers a fresh response.created id if the continuation emits one" do
      sse = +""
      sse << "id: 6\nevent: response.created\ndata: {\"response\":{\"id\":\"resp_new\"}}\n\n"
      sse << "data: [DONE]\n\n"
      stub_request(:get, "http://termllm.test/chat/v1/responses/resp_old/events?after=0").to_return(
        status: 200,
        body: sse,
        headers: { "Content-Type" => "text/event-stream" },
      )

      result = client.stream_events(response_id: "resp_old", after: 0)

      expect(result[:response_id]).to eq("resp_new")
    end
  end
end
