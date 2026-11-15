module Webhooks
  class GitHubController < ApplicationController
    skip_before_action :verify_authenticity_token

    def create
      payload_body = request.raw_post
      signature = request.headers["X-Hub-Signature-256"]
      event_type = request.headers["X-GitHub-Event"]
      delivery_id = request.headers["X-GitHub-Delivery"]

      unless valid_signature?(payload_body, signature)
        head :unauthorized
        return
      end

      if event_type == "ping"
        head :ok
        return
      end

      payload = JSON.parse(payload_body) rescue {}
      handler = Omochi::GitHub::EventHandler.new
      handler.handle(event_type: event_type, delivery_id: delivery_id, payload: payload)

      head :ok
    end

    private
      def valid_signature?(payload_body, signature_header)
        secret = Omochi::Settings.dig(:github, :webhook_secret)
        # If no secret configured, reject for security in production/development
        return false if secret.blank? || signature_header.blank?

        expected_signature = "sha256=" + OpenSSL::HMAC.hexdigest(
          OpenSSL::Digest::SHA256.new,
          secret,
          payload_body
        )

        Rack::Utils.secure_compare(expected_signature, signature_header)
      end
  end
end
