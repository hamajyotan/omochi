module Omochi
  module Slack
    class Error < StandardError; end
    class ApiError < Error; end
    class RateLimitedError < ApiError
      attr_reader :retry_after

      def initialize(message, retry_after: nil)
        super(message)
        @retry_after = retry_after
      end
    end

    mattr_accessor :web_client_factory, default: -> { WebClient.new }

    def self.build_web_client
      web_client_factory.call
    end
  end
end
