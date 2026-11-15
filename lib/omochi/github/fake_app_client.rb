# In-memory test double for `Omochi::GitHub::AppClient`.
module Omochi
  module GitHub
    class FakeAppClient
      attr_reader :reviews, :comments, :created_pull_requests, :tokens_requested
      attr_accessor :on_create_review, :on_create_comment, :on_create_pull_request, :pull_requests, :pull_request_diffs

      def initialize
        @reviews = []
        @comments = []
        @created_pull_requests = []
        @tokens_requested = []
        @pull_requests = {}
        @pull_request_diffs = {}
      end

      def installation_token(installation_id)
        @tokens_requested << installation_id
        "ghs_fake_token_#{installation_id}"
      end

      def installation_id_for(_repository)
        1
      end

      def create_pull_request(installation_id:, repository:, title:, body:, head:, base: "main")
        if @on_create_pull_request
          return @on_create_pull_request.call(installation_id:, repository:, title:, body:, head:, base:)
        end

        number = 100 + @created_pull_requests.size + 1
        record = {
          installation_id: installation_id,
          repository: repository.to_s,
          number: number,
          title: title.to_s,
          body: body.to_s,
          head: head.to_s,
          base: base.to_s,
          html_url: "https://github.com/#{repository}/pull/#{number}"
        }
        @created_pull_requests << record
        {
          "id" => 5000 + number,
          "number" => number,
          "title" => record[:title],
          "body" => record[:body],
          "html_url" => record[:html_url],
          "head" => { "ref" => record[:head] },
          "base" => { "ref" => record[:base] }
        }
      end

      def fetch_pull_request(installation_id:, repository:, pull_number:)
        key = "#{repository}##{pull_number}"
        @pull_requests[key] || {
          "number" => pull_number.to_i,
          "title" => "PR ##{pull_number}",
          "body" => "PR description",
          "html_url" => "https://github.com/#{repository}/pull/#{pull_number}",
          "base" => { "ref" => "main", "sha" => "base_sha_123" },
          "head" => { "ref" => "feature-branch", "sha" => "head_sha_456" }
        }
      end

      def fetch_pull_request_diff(installation_id:, repository:, pull_number:)
        key = "#{repository}##{pull_number}"
        @pull_request_diffs[key] || <<~DIFF
          diff --git a/README.md b/README.md
          index 1111111..2222222 100644
          --- a/README.md
          +++ b/README.md
          @@ -1 +1,2 @@
           # omochi
          +Added line in PR ##{pull_number}
        DIFF
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
