require "json"
require "net/http"
require "uri"

module Omochi
  module Slack
    class OAuthClient
      AUTH_URL = "https://slack.com/openid/connect/authorize".freeze
      TOKEN_URL = "https://slack.com/api/openid.connect.token".freeze
      USER_INFO_URL = "https://slack.com/api/openid.connect.userInfo".freeze
      OPEN_TIMEOUT_SECONDS = 5
      READ_TIMEOUT_SECONDS = 10

      class AuthenticationError < Omochi::Slack::Error; end

      def initialize(
        client_id: -> { Omochi::Settings.fetch!(:slack, :client_id) },
        client_secret: -> { Omochi::Settings.fetch!(:slack, :client_secret) },
        team_id: -> { Omochi::Settings.dig(:slack, :team_id) },
        http_requester: method(:default_http_request)
      )
        @client_id = client_id
        @client_secret = client_secret
        @team_id = team_id
        @http_requester = http_requester
      end

      def authorize_url(state:, redirect_uri:)
        params = {
          response_type: "code",
          scope: "openid profile email",
          client_id: resolve(@client_id),
          redirect_uri: redirect_uri,
          state: state
        }
        team = resolve(@team_id).to_s.strip
        params[:team] = team unless team.empty?

        "#{AUTH_URL}?#{URI.encode_www_form(params)}"
      end

      def exchange_code(code:, redirect_uri:)
        uri = URI.parse(TOKEN_URL)
        form = URI.encode_www_form(
          client_id: resolve(@client_id),
          client_secret: resolve(@client_secret),
          code: code,
          redirect_uri: redirect_uri
        )

        response = @http_requester.call(
          uri,
          method: :post,
          headers: {
            "Accept" => "application/json",
            "Content-Type" => "application/x-www-form-urlencoded"
          },
          body: form
        )

        handle_token_response(response)
      end

      def fetch_user(access_token)
        uri = URI.parse(USER_INFO_URL)
        response = @http_requester.call(
          uri,
          method: :get,
          headers: {
            "Authorization" => "Bearer #{access_token}",
            "Accept" => "application/json"
          },
          body: nil
        )

        handle_user_response(response)
      end

      private
        def resolve(val_or_proc)
          val_or_proc.respond_to?(:call) ? val_or_proc.call : val_or_proc
        end

        def handle_token_response(response)
          code = response.code.to_i
          body = JSON.parse(response.body.to_s) rescue {}

          unless code.between?(200, 299) && body["ok"] == true && body["access_token"].present?
            error_desc = body["error"].presence || "HTTP #{code}"
            raise AuthenticationError, "Failed to exchange Slack OIDC code: #{error_desc}"
          end

          body["access_token"]
        end

        def handle_user_response(response)
          code = response.code.to_i
          body = JSON.parse(response.body.to_s) rescue {}

          unless code.between?(200, 299) && body["ok"] == true && body["sub"].present?
            error_desc = body["error"].presence || "HTTP #{code}"
            raise AuthenticationError, "Failed to fetch Slack user info: #{error_desc}"
          end

          body
        end

        def default_http_request(uri, method:, headers:, body:)
          Net::HTTP.start(
            uri.host,
            uri.port,
            use_ssl: uri.scheme == "https",
            open_timeout: OPEN_TIMEOUT_SECONDS,
            read_timeout: READ_TIMEOUT_SECONDS
          ) do |http|
            request = (method == :get) ? Net::HTTP::Get.new(uri.request_uri) : Net::HTTP::Post.new(uri.request_uri)
            headers.each { |k, v| request[k] = v }
            request.body = body if body
            http.request(request)
          end
        end
    end
  end
end
