require "json"
require "net/http"
require "uri"

module Omochi
  module GitHub
    class OAuthClient
      AUTH_URL = "https://github.com/login/oauth/authorize".freeze
      TOKEN_URL = "https://github.com/login/oauth/access_token".freeze
      USER_API_URL = "https://api.github.com/user".freeze
      OPEN_TIMEOUT_SECONDS = 5
      READ_TIMEOUT_SECONDS = 10

      class AuthenticationError < StandardError; end

      def initialize(
        client_id: -> { Omochi::Settings.fetch!(:github, :client_id) },
        client_secret: -> { Omochi::Settings.fetch!(:github, :client_secret) },
        http_requester: method(:default_http_request)
      )
        @client_id = client_id
        @client_secret = client_secret
        @http_requester = http_requester
      end

      def authorize_url(state:, redirect_uri:)
        id = resolve(@client_id)
        params = URI.encode_www_form(
          client_id: id,
          redirect_uri: redirect_uri,
          scope: "read:user",
          state: state
        )
        "#{AUTH_URL}?#{params}"
      end

      def exchange_code(code:, redirect_uri:)
        uri = URI.parse(TOKEN_URL)
        payload = {
          client_id: resolve(@client_id),
          client_secret: resolve(@client_secret),
          code: code,
          redirect_uri: redirect_uri
        }

        response = @http_requester.call(
          uri,
          method: :post,
          headers: { "Accept" => "application/json", "Content-Type" => "application/json" },
          body: JSON.generate(payload)
        )

        handle_token_response(response)
      end

      def fetch_user(access_token)
        uri = URI.parse(USER_API_URL)
        response = @http_requester.call(
          uri,
          method: :get,
          headers: {
            "Authorization" => "Bearer #{access_token}",
            "Accept" => "application/vnd.github+json",
            "X-GitHub-Api-Version" => "2022-11-28",
            "User-Agent" => "omochi-app"
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

          unless code.between?(200, 299) && body["access_token"].present?
            error_desc = body["error_description"].presence || body["error"] || "HTTP #{code}"
            raise AuthenticationError, "Failed to exchange GitHub OAuth code: #{error_desc}"
          end

          body["access_token"]
        end

        def handle_user_response(response)
          code = response.code.to_i
          body = JSON.parse(response.body.to_s) rescue {}

          unless code.between?(200, 299) && body["login"].present?
            raise AuthenticationError, "Failed to fetch GitHub user info: HTTP #{code}"
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
