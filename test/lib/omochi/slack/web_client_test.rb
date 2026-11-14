require "test_helper"

class Omochi::Slack::WebClientTest < ActiveSupport::TestCase
  FakeResponse = Struct.new(:code, :body, :headers) do
    def [](key)
      headers&.fetch(key, nil)
    end
  end

  test "open_socket_connection posts to apps.connections.open with the app token" do
    captured = nil
    requester = ->(uri, token:, body:) do
      captured = { uri: uri.to_s, token: token, body: body }
      FakeResponse.new("200", '{"ok":true,"url":"wss://wss-primary.slack.com/link"}', {})
    end

    client = Omochi::Slack::WebClient.new(
      bot_token: "xoxb-bot",
      app_token: "xapp-socket",
      http_requester: requester
    )

    assert_equal "wss://wss-primary.slack.com/link", client.open_socket_connection
    assert_equal "https://slack.com/api/apps.connections.open", captured[:uri]
    assert_equal "xapp-socket", captured[:token]
  end

  test "post_message posts thread reply with the bot token" do
    captured = nil
    requester = ->(uri, token:, body:) do
      captured = { uri: uri.to_s, token: token, body: JSON.parse(body) }
      FakeResponse.new("200", '{"ok":true,"ts":"1700000000.000200"}', {})
    end

    client = Omochi::Slack::WebClient.new(
      bot_token: "xoxb-bot",
      app_token: "xapp-socket",
      http_requester: requester
    )

    response = client.post_message(channel: "C123", thread_ts: "1700000000.000100", text: "Hello")
    assert_equal true, response["ok"]
    assert_equal "xoxb-bot", captured[:token]
    assert_equal({ "channel" => "C123", "thread_ts" => "1700000000.000100", "text" => "Hello" }, captured[:body])
  end

  test "raises RateLimitedError on HTTP 429 and ApiError on ok:false" do
    rate_limited = Omochi::Slack::WebClient.new(
      bot_token: "xoxb-bot",
      app_token: "xapp-socket",
      http_requester: ->(_uri, **) { FakeResponse.new("429", "", { "Retry-After" => "7" }) }
    )
    err = assert_raises(Omochi::Slack::RateLimitedError) do
      rate_limited.post_message(channel: "C1", thread_ts: "1.1", text: "hi")
    end
    assert_equal 7, err.retry_after

    api_error = Omochi::Slack::WebClient.new(
      bot_token: "xoxb-bot",
      app_token: "xapp-socket",
      http_requester: ->(_uri, **) { FakeResponse.new("200", '{"ok":false,"error":"channel_not_found"}', {}) }
    )
    err2 = assert_raises(Omochi::Slack::ApiError) do
      api_error.post_message(channel: "C1", thread_ts: "1.1", text: "hi")
    end
    assert_includes err2.message, "channel_not_found"
  end
end
