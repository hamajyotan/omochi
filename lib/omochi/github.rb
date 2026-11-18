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
    mattr_accessor :workspace_syncer_factory, default: -> { WorkspaceSyncer.new }

    def self.build_app_client
      app_client_factory.call
    end

    def self.build_workspace_syncer
      workspace_syncer_factory.call
    end
  end
end
