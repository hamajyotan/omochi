require "test_helper"

class Webhooks::GitHubControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  setup do
    @secret = "webhook_secret_test_xyz"
    @original_secret = Omochi::Settings.dig(:github, :webhook_secret)
    Rails.configuration.omochi[:github] ||= {}
    Rails.configuration.omochi[:github][:webhook_secret] = @secret
  end

  teardown do
    Rails.configuration.omochi[:github][:webhook_secret] = @original_secret
  end

  def compute_signature(body, secret = @secret)
    "sha256=" + OpenSSL::HMAC.hexdigest(OpenSSL::Digest::SHA256.new, secret, body)
  end

  test "accepts valid signature and handles review_requested webhook" do
    payload = {
      "action" => "review_requested",
      "pull_request" => {
        "number" => 10,
        "title" => "PR 10",
        "html_url" => "https://github.com/hamajyotan/omochi/pull/10",
        "user" => { "login" => "alice" },
        "base" => { "ref" => "main" },
        "head" => { "ref" => "patch", "sha" => "111" }
      },
      "repository" => { "full_name" => "hamajyotan/omochi" },
      "requested_reviewer" => { "login" => "omochi" }
    }.to_json

    assert_difference -> { Quest.count } => 1 do
      post webhooks_github_path,
        headers: {
          "X-Hub-Signature-256" => compute_signature(payload),
          "X-GitHub-Event" => "pull_request",
          "X-GitHub-Delivery" => "deliv_100",
          "Content-Type" => "application/json"
        },
        params: payload
    end

    assert_response :ok
    assert Quest.last.instructions.first.queued?
  end

  test "rejects invalid HMAC signature with 401" do
    payload = '{"action":"ping"}'

    post webhooks_github_path,
      headers: {
        "X-Hub-Signature-256" => compute_signature(payload, "wrong_secret"),
        "X-GitHub-Event" => "ping",
        "X-GitHub-Delivery" => "deliv_bad"
      },
      params: payload

    assert_response :unauthorized
  end

  test "ping event returns 200 ok without creating a Quest" do
    payload = '{"zen":"Keep it logically awesome."}'

    assert_no_difference -> { Quest.count } do
      post webhooks_github_path,
        headers: {
          "X-Hub-Signature-256" => compute_signature(payload),
          "X-GitHub-Event" => "ping",
          "X-GitHub-Delivery" => "deliv_ping"
        },
        params: payload
    end

    assert_response :ok
  end
end
