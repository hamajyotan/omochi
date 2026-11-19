require "test_helper"

class Omochi::SecretRedactorTest < ActiveSupport::TestCase
  test "redacts configured gemini_api_key and AIza patterns" do
    orig_key = Rails.configuration.omochi[:docker][:gemini_api_key]
    Rails.configuration.omochi[:docker][:gemini_api_key] = "custom-secret-key-12345"

    begin
      text = "Key is custom-secret-key-12345 and AIzaSyDummyTestKey1234567890abcd"
      redacted = Omochi::SecretRedactor.redact(text)

      assert_equal "Key is [REDACTED] and [REDACTED]", redacted
    ensure
      Rails.configuration.omochi[:docker][:gemini_api_key] = orig_key
    end
  end

  test "redacts secrets from quest execution events, summary, and errors" do
    orig_key = Rails.configuration.omochi[:docker][:gemini_api_key]
    Rails.configuration.omochi[:docker][:gemini_api_key] = "secret_gemini_token_999"

    begin
      instruction = Quest.start!(
        title: "Redaction test",
        body: "test",
        source_platform: "dashboard",
        enqueue: false
      )
      execution = instruction.quest.claim_next_instruction!
      execution.mark_running!(container_id: "cid_redact")

      event = execution.record_output_line!(
        %({"type":"progress","message":"leaked secret_gemini_token_999"}\n),
        stream: "stdout"
      )
      assert_equal "leaked [REDACTED]", event.message

      execution.succeed!(result_summary: "done with secret_gemini_token_999", exit_code: 0)
      assert_equal "done with [REDACTED]", execution.reload.result_summary

      execution2 = instruction.quest.receive_instruction!(body: "retry", source_platform: "dashboard", enqueue: false)
      exec2 = instruction.quest.claim_next_instruction!
      exec2.fail!(error_kind: "agent_error", error_message: "failed: secret_gemini_token_999")
      assert_equal "failed: [REDACTED]", exec2.reload.error_message
    ensure
      Rails.configuration.omochi[:docker][:gemini_api_key] = orig_key
    end
  end
end
