# Masks configured secrets and common API key patterns before persisting or
# broadcasting Agent Container output, summaries, or error messages.
module Omochi
  module SecretRedactor
    REDACTED = "[REDACTED]".freeze
    GEMINI_KEY_PATTERN = /\bAIza[0-9A-Za-z\-_]{20,}\b/
    MIN_SECRET_LENGTH = 8

    module_function

    def redact(text)
      return nil if text.nil?

      result = text.to_s.dup.force_encoding(Encoding::UTF_8).scrub
      return result if result.empty?

      configured_secrets.each do |secret|
        result = result.gsub(secret, REDACTED)
      end

      result.gsub(GEMINI_KEY_PATTERN, REDACTED)
    end

    def configured_secrets
      candidates = [
        Omochi::Settings.dig(:docker, :gemini_api_key),
        Omochi::Settings.dig(:slack, :bot_token),
        Omochi::Settings.dig(:slack, :app_token),
        Omochi::Settings.dig(:slack, :client_secret),
        Omochi::Settings.dig(:github, :webhook_secret)
      ]

      candidates
        .filter_map { |value| value.to_s.strip.presence }
        .select { |value| value.length >= MIN_SECRET_LENGTH }
        .uniq
        .sort_by { |value| -value.length }
    end
  end
end
