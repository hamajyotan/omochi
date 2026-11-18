require "test_helper"

class Omochi::Slack::OAuthClientTest < ActiveSupport::TestCase
  test "authorize_url builds valid Slack OpenID Connect URL with state, redirect_uri, and optional team" do
    client = Omochi::Slack::OAuthClient.new(
      client_id: "123.456",
      client_secret: "test_secret",
      team_id: "T012345"
    )

    url = client.authorize_url(state: "abc123state", redirect_uri: "https://omochi.example.com/auth/slack/callback")
    uri = URI.parse(url)
    params = URI.decode_www_form(uri.query).to_h

    assert_equal "https", uri.scheme
    assert_equal "slack.com", uri.host
    assert_equal "/openid/connect/authorize", uri.path
    assert_equal "code", params["response_type"]
    assert_equal "openid profile email", params["scope"]
    assert_equal "123.456", params["client_id"]
    assert_equal "https://omochi.example.com/auth/slack/callback", params["redirect_uri"]
    assert_equal "abc123state", params["state"]
    assert_equal "T012345", params["team"]
  end

  test "exchange_code returns access_token on success" do
    fake_response = Struct.new(:code, :body)
    requester = ->(uri, method:, headers:, body:) do
      assert_equal :post, method
      assert_equal "/api/openid.connect.token", uri.path
      assert_equal "application/x-www-form-urlencoded", headers["Content-Type"]
      form_params = URI.decode_www_form(body).to_h
      assert_equal "id", form_params["client_id"]
      assert_equal "secret", form_params["client_secret"]
      assert_equal "code_123", form_params["code"]
      fake_response.new("200", { ok: true, access_token: "xoxp-slack-oidc-token" }.to_json)
    end

    client = Omochi::Slack::OAuthClient.new(
      client_id: "id",
      client_secret: "secret",
      http_requester: requester
    )

    token = client.exchange_code(code: "code_123", redirect_uri: "https://omochi.example.com/auth/slack/callback")
    assert_equal "xoxp-slack-oidc-token", token
  end

  test "exchange_code raises AuthenticationError on error response" do
    fake_response = Struct.new(:code, :body)
    requester = ->(_uri, method:, headers:, body:) do
      fake_response.new("200", { ok: false, error: "invalid_code" }.to_json)
    end

    client = Omochi::Slack::OAuthClient.new(
      client_id: "id",
      client_secret: "secret",
      http_requester: requester
    )

    err = assert_raises(Omochi::Slack::OAuthClient::AuthenticationError) do
      client.exchange_code(code: "bad", redirect_uri: "https://omochi.example.com/auth/slack/callback")
    end
    assert_includes err.message, "invalid_code"
  end

  test "fetch_user returns parsed user info on success" do
    fake_response = Struct.new(:code, :body)
    requester = ->(uri, method:, headers:, body:) do
      assert_equal :get, method
      assert_equal "/api/openid.connect.userInfo", uri.path
      assert_equal "Bearer my_token", headers["Authorization"]
      fake_response.new("200", {
        "ok" => true,
        "sub" => "U01234567",
        "https://slack.com/team_id" => "T01234567",
        "name" => "Takashi",
        "email" => "takashi@example.com",
        "picture" => "https://example.com/avatar.png"
      }.to_json)
    end

    client = Omochi::Slack::OAuthClient.new(
      client_id: "id",
      client_secret: "secret",
      http_requester: requester
    )

    user = client.fetch_user("my_token")
    assert_equal "U01234567", user["sub"]
    assert_equal "T01234567", user["https://slack.com/team_id"]
    assert_equal "Takashi", user["name"]
  end
end
