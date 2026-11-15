module Omochi
  module GitHub
    class Error < StandardError; end
    class ApiError < Error; end
    class AuthenticationError < Error; end
    class RateLimitedError < ApiError
      attr_reader :retry_after

      def initialize(message, retry_after: nil)
        super(message)
        @retry_after = retry_after
      end
    end

    mattr_accessor :app_client_factory, default: -> { AppClient.new }
    mattr_accessor :oauth_client_factory, default: -> { OAuthClient.new }

    def self.build_app_client
      app_client_factory.call
    end

    def self.build_oauth_client
      oauth_client_factory.call
    end
  end
end
