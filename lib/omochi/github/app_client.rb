require "base64"
require "json"
require "net/http"
require "openssl"
require "uri"

# Lightweight GitHub App REST API client built on Ruby's standard library.
#
# Generates RS256 JWTs from the GitHub App Private Key, requests short-lived
# Installation Access Tokens (valid for 1 hour), and posts PR Reviews / Comments.
# All tokens and private keys live on the host only and are never passed to
# Agent Containers.
module Omochi
  module GitHub
    class AppClient
      DEFAULT_BASE_URL = "https://api.github.com".freeze
      OPEN_TIMEOUT_SECONDS = 5
      READ_TIMEOUT_SECONDS = 15

      def initialize(
        app_id: -> { Omochi::Settings.fetch!(:github, :app_id) },
        private_key: -> { Omochi::Settings.fetch!(:github, :private_key) },
        base_url: DEFAULT_BASE_URL,
        http_requester: method(:default_http_request)
      )
        @app_id = app_id
        @private_key = private_key
        @base_url = base_url.chomp("/")
        @http_requester = http_requester
        @installation_tokens = {}
      end

      # Generates a signed JWT (RS256) valid for 10 minutes.
      def generate_jwt
        key_data = resolve(@private_key).to_s
        rsa_key =
          if File.exist?(key_data)
            OpenSSL::PKey::RSA.new(File.read(key_data))
          else
            OpenSSL::PKey::RSA.new(key_data.gsub('\n', "\n"))
          end

        header = { alg: "RS256", typ: "JWT" }
        now = Time.now.to_i
        payload = {
          iss: resolve(@app_id).to_s,
          iat: now - 60,
          exp: now + (9 * 60)
        }

        unsigned = "#{base64_url(header.to_json)}.#{base64_url(payload.to_json)}"
        signature = rsa_key.sign(OpenSSL::Digest::SHA256.new, unsigned)
        "#{unsigned}.#{base64_url(signature)}"
      rescue OpenSSL::PKey::RSAError => e
        raise AuthenticationError, "Invalid GitHub App Private Key: #{e.message}"
      end

      # Retrieves an Installation Access Token for a repository's installation.
      def installation_token(installation_id)
        cached = @installation_tokens[installation_id]
        return cached[:token] if cached && cached[:expires_at] > Time.now.to_i + 60

        jwt = generate_jwt
        response = post_json(
          "app/installations/#{installation_id}/access_tokens",
          bearer_token: jwt,
          payload: {}
        )

        token = response["token"]
        expires_at = Time.iso8601(response["expires_at"]).to_i rescue (Time.now.to_i + 3500)
        @installation_tokens[installation_id] = { token: token, expires_at: expires_at }
        token
      end

      # Submits a Pull Request Review (e.g. COMMENT, APPROVE, REQUEST_CHANGES).
      def create_pull_request_review(installation_id:, repository:, pull_number:, body:, event: "COMMENT")
        token = installation_token(installation_id)
        post_json(
          "repos/#{repository}/pulls/#{pull_number}/reviews",
          bearer_token: token,
          payload: {
            body: body.to_s,
            event: event.to_s.upcase
          }
        )
      end

      # Posts an Issue Comment (used for issues or regular PR conversation comments).
      def create_issue_comment(installation_id:, repository:, issue_number:, body:)
        token = installation_token(installation_id)
        post_json(
          "repos/#{repository}/issues/#{issue_number}/comments",
          bearer_token: token,
          payload: { body: body.to_s }
        )
      end

      private
        def resolve(value_or_proc)
          value_or_proc.respond_to?(:call) ? value_or_proc.call : value_or_proc
        end

        def base64_url(str)
          Base64.urlsafe_encode64(str, padding: false)
        end

        def post_json(endpoint, bearer_token:, payload:)
          uri = URI.parse("#{@base_url}/#{endpoint}")
          response = @http_requester.call(
            uri,
            token: bearer_token,
            body: payload.empty? ? nil : JSON.generate(payload)
          )

          handle_http_response(response, endpoint)
        end

        def handle_http_response(response, endpoint)
          code = response.code.to_i
          if code == 429
            retry_after = response["Retry-After"]&.to_i
            raise RateLimitedError.new("GitHub rate limited #{endpoint}", retry_after: retry_after)
          end

          unless code.between?(200, 299)
            raise ApiError, "GitHub HTTP #{code} on #{endpoint}: #{response.body.to_s.truncate(500)}"
          end

          JSON.parse(response.body.to_s)
        rescue JSON::ParserError => e
          raise ApiError, "Invalid JSON from GitHub #{endpoint}: #{e.message}"
        rescue SocketError, SystemCallError, IOError, Net::OpenTimeout, Net::ReadTimeout => e
          raise ApiError, "GitHub network error on #{endpoint}: #{e.class}: #{e.message}"
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
            request["Accept"] = "application/vnd.github+json"
            request["X-GitHub-Api-Version"] = "2022-11-28"
            if body
              request["Content-Type"] = "application/json; charset=utf-8"
              request.body = body
            end
            http.request(request)
          end
        end
    end
  end
end
