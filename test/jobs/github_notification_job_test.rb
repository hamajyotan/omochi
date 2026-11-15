require "test_helper"

class GitHubNotificationJobTest < ActiveJob::TestCase
  test "posts review comment back to GitHub Pull Request on execution finish" do
    quest = start_quest(title: "Review PR #5", body: "Check PR")
    resource = quest.external_resources.create!(
      platform: "github",
      resource_type: "pull_request",
      scope_key: "hamajyotan/omochi",
      external_id: "5",
      url: "https://github.com/hamajyotan/omochi/pull/5"
    )
    instruction = quest.instructions.sole
    instruction.update!(external_resource: resource)

    execution = quest.claim_next_instruction!
    execution.mark_running!

    assert_enqueued_with(job: GitHubNotificationJob) do
      execution.succeed!(result_summary: "LGTM! All checks passed.")
    end

    perform_enqueued_jobs

    review = @fake_github_client.reviews.sole
    assert_equal "hamajyotan/omochi", review[:repository]
    assert_equal "5", review[:pull_number]
    assert_includes review[:body], "LGTM! All checks passed."
    assert_equal "COMMENT", review[:event]
  end
end
