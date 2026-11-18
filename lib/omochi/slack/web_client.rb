require "json"
require "net/http"
require "uri"

# Minimal Slack Web API client built on Ruby's standard `Net::HTTP`.
#
# Tokens are read on the host only (`Omochi::Settings`) and are never logged or
# forwarded to Agent Containers.
module Omochi
  module Slack
    class WebClient
      DEFAULT_BASE_URL = "https://slack.com/api".freeze
      OPEN_TIMEOUT_SECONDS = 5
      READ_TIMEOUT_SECONDS = 15

      def initialize(
        bot_token: -> { Omochi::Settings.fetch!(:slack, :bot_token) },
        app_token: -> { Omochi::Settings.fetch!(:slack, :app_token) },
        base_url: DEFAULT_BASE_URL,
        http_requester: method(:default_http_request)
      )
        @bot_token = bot_token
        @app_token = app_token
        @base_url = base_url.chomp("/")
        @http_requester = http_requester
      end

      # Requests a fresh Socket Mode WSS URL using the App-Level Token (`xapp-...`).
      def open_socket_connection
        body = post_json("apps.connections.open", token: resolve(@app_token), payload: {})
        url = body["url"].to_s
        raise ApiError, "apps.connections.open did not return a wss URL" unless url.start_with?("wss://")

        url
      end

      # Posts a reply inside a Slack thread using the Bot Token (`xoxb-...`).
      def post_message(channel:, thread_ts:, text:)
        post_json(
          "chat.postMessage",
          token: resolve(@bot_token),
          payload: {
            channel: channel.to_s,
            thread_ts: thread_ts.to_s,
            text: text.to_s
          }
        )
      end

      # Adds an emoji reaction (e.g. "eyes") to a message. Treats "already_reacted" as success.
      def add_reaction(channel:, timestamp:, name:)
        post_json(
          "reactions.add",
          token: resolve(@bot_token),
          payload: {
            channel: channel.to_s,
            timestamp: timestamp.to_s,
            name: name.to_s
          },
          ignored_errors: %w[already_reacted]
        )
      end

      # Removes an emoji reaction from a message. Treats "no_reaction" as success.
      def remove_reaction(channel:, timestamp:, name:)
        post_json(
          "reactions.remove",
          token: resolve(@bot_token),
          payload: {
            channel: channel.to_s,
            timestamp: timestamp.to_s,
            name: name.to_s
          },
          ignored_errors: %w[no_reaction]
        )
      end

      # Downloads a private Slack file (e.g. image attachment) using the Bot Token.
      # Authorization header is only sent to `*.slack.com` hosts.
      def download_file(url, max_bytes: 10 * 1024 * 1024, max_redirects: 3)
        current_url = url.to_s
        token = resolve(@bot_token)

        (max_redirects + 1).times do
          uri = URI.parse(current_url)
          raise ApiError, "Invalid Slack file URL scheme" unless uri.is_a?(URI::HTTPS)

          headers = {}
          if uri.host&.end_with?(".slack.com") || uri.host == "slack.com"
            headers["Authorization"] = "Bearer #{token}"
          end

          response = Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: true,
            open_timeout: OPEN_TIMEOUT_SECONDS,
            read_timeout: READ_TIMEOUT_SECONDS
          ) do |http|
            req = Net::HTTP::Get.new(uri.request_uri)
            headers.each { |k, v| req[k] = v }
            http.request(req)
          end

          if response.is_a?(Net::HTTPRedirection) && response["location"].present?
            current_url = URI.join(uri, response["location"]).to_s
            next
          end

          unless response.code.to_i.between?(200, 299)
            raise ApiError, "Slack file download failed: HTTP #{response.code}"
          end

          body = response.body.to_s
          if body.bytesize > max_bytes
            raise ApiError, "Slack file exceeds maximum allowed size (#{body.bytesize} > #{max_bytes})"
          end

          return body
        end

        raise ApiError, "Too many redirects downloading Slack file"
      rescue URI::InvalidURIError => e
        raise ApiError, "Invalid Slack file URL: #{e.message}"
      rescue SocketError, SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout => e
        raise ApiError, "Slack file download network error: #{e.class}: #{e.message}"
      end

      private
        def resolve(value_or_proc)
          value_or_proc.respond_to?(:call) ? value_or_proc.call : value_or_proc
        end

        def post_json(endpoint, token:, payload:, ignored_errors: [])
          uri = URI.parse("#{@base_url}/#{endpoint}")
          response = @http_requester.call(uri, token: token, body: JSON.generate(payload))

          if response.code.to_i == 429
            retry_after = response["Retry-After"]&.to_i
            raise RateLimitedError.new("Slack rate limited #{endpoint}", retry_after: retry_after)
          end

          unless response.code.to_i.between?(200, 299)
            raise ApiError, "Slack HTTP #{response.code} on #{endpoint}"
          end

          parsed = JSON.parse(response.body.to_s)
          unless parsed["ok"] == true || ignored_errors.include?(parsed["error"].to_s)
            raise ApiError, "Slack API error on #{endpoint}: #{parsed['error'] || 'unknown_error'}"
          end

          parsed
        rescue JSON::ParserError => e
          raise ApiError, "Invalid JSON from Slack #{endpoint}: #{e.message}"
        rescue SocketError, SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout => e
          raise ApiError, "Slack network error on #{endpoint}: #{e.class}: #{e.message}"
        end

        def default_http_request(uri, token:, body:)
          Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: OPEN_TIMEOUT_SECONDS,
            read_timeout: READ_TIMEOUT_SECONDS
          ) do |http|
            request = Net::HTTP::Post.new(uri.request_uri)
            request["Authorization"] = "Bearer #{token}"
            request["Content-Type"] = "application/json; charset=utf-8"
            request.body = body
            http.request(request)
          end
        end
    end
  end
end
