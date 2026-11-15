require "test_helper"

class Omochi::GitHub::OAuthClientTest < ActiveSupport::TestCase
  test "authorize_url constructs valid GitHub authorize URL" do
    client = Omochi::GitHub::OAuthClient.new(
      client_id: "test_client_id",
      client_secret: "test_secret"
    )

    url = client.authorize_url(state: "xyz123", redirect_uri: "https://example.com/callback")
    uri = URI.parse(url)

    assert_equal "github.com", uri.host
    assert_equal "/login/oauth/authorize", uri.path
    params = URI.decode_www_form(uri.query).to_h
    assert_equal "test_client_id", params["client_id"]
    assert_equal "https://example.com/callback", params["redirect_uri"]
    assert_equal "read:user", params["scope"]
    assert_equal "xyz123", params["state"]
  end

  test "exchange_code parses access token from response" do
    fake_response = Struct.new(:code, :body)
    requester = ->(uri, method:, headers:, body:) do
      assert_equal :post, method
      fake_response.new("200", { access_token: "gho_secret_token_abc" }.to_json)
    end

    client = Omochi::GitHub::OAuthClient.new(
      client_id: "id",
      client_secret: "secret",
      http_requester: requester
    )

    token = client.exchange_code(code: "code123", redirect_uri: "https://example.com/cb")
    assert_equal "gho_secret_token_abc", token
  end

  test "fetch_user returns user info hash" do
    fake_response = Struct.new(:code, :body)
    requester = ->(uri, method:, headers:, body:) do
      assert_equal :get, method
      assert_equal "Bearer gho_token", headers["Authorization"]
      fake_response.new("200", { login: "hamajyotan", id: 101, name: "Takashi" }.to_json)
    end

    client = Omochi::GitHub::OAuthClient.new(
      client_id: "id",
      client_secret: "secret",
      http_requester: requester
    )

    user = client.fetch_user("gho_token")
    assert_equal "hamajyotan", user["login"]
    assert_equal 101, user["id"]
  end
end
