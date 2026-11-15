# In-memory test double for `Omochi::GitHub::AppClient`.
module Omochi
  module GitHub
    class FakeAppClient
      attr_reader :reviews, :comments, :tokens_requested
      attr_accessor :on_create_review, :on_create_comment

      def initialize
        @reviews = []
        @comments = []
        @tokens_requested = []
      end

      def installation_token(installation_id)
        @tokens_requested << installation_id
        "ghs_fake_token_#{installation_id}"
      end

      def installation_id_for(_repository)
        1
      end

      def create_pull_request_review(installation_id:, repository:, pull_number:, body:, event: "COMMENT")
        return @on_create_review.call(installation_id:, repository:, pull_number:, body:, event:) if @on_create_review

        record = { installation_id:, repository:, pull_number:, body: body.to_s, event: event.to_s }
        @reviews << record
        { "id" => 101, "state" => event.to_s.upcase, "body" => body.to_s }
      end

      def create_issue_comment(installation_id:, repository:, issue_number:, body:)
        return @on_create_comment.call(installation_id:, repository:, issue_number:, body:) if @on_create_comment

        record = { installation_id:, repository:, issue_number:, body: body.to_s }
        @comments << record
        { "id" => 201, "body" => body.to_s }
      end
    end
  end
end
