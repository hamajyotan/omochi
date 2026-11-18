require "test_helper"

class Omochi::GitHub::PullRequestMergerTest < ActiveSupport::TestCase
  test "parse_command recognizes valid /merge commands and rejects arbitrary sentences" do
    assert_equal(
      { merge_method: "merge", pr_url: nil, repository: nil, pull_number: nil },
      Omochi::GitHub::PullRequestMerger.parse_command("/merge")
    )
    assert_equal(
      { merge_method: "squash", pr_url: nil, repository: nil, pull_number: nil },
      Omochi::GitHub::PullRequestMerger.parse_command("  /merge   squash  ")
    )
    assert_equal(
      {
        merge_method: "rebase",
        pr_url: "https://github.com/hamajyotan/omochi/pull/12",
        repository: "hamajyotan/omochi",
        pull_number: 12
      },
      Omochi::GitHub::PullRequestMerger.parse_command("/merge https://github.com/hamajyotan/omochi/pull/12 rebase")
    )

    assert_nil Omochi::GitHub::PullRequestMerger.parse_command("マージして")
    assert_nil Omochi::GitHub::PullRequestMerger.parse_command("/merge したらどうなりますか？")
    assert_nil Omochi::GitHub::PullRequestMerger.parse_command("/review")
  end

  test "merges the Pull Request associated with the Quest" do
    quest = start_quest(body: "Update README.md")
    quest.external_resources.create!(
      platform: "github",
      resource_type: "pull_request",
      scope_key: "hamajyotan/omochi",
      external_id: "7",
      url: "https://github.com/hamajyotan/omochi/pull/7"
    )
    quest.receive_instruction!(body: "/merge squash", source_platform: "slack", enqueue: false)
    # Claim initial instruction and succeed it first
    first_exec = quest.claim_next_instruction!
    first_exec.succeed!(result_summary: "Created PR #7")

    merge_exec = quest.claim_next_instruction!
    merger = Omochi::GitHub::PullRequestMerger.new(app_client: @fake_github_client)
    result = merger.merge!(merge_exec)

    assert_equal "hamajyotan/omochi", result["repository"]
    assert_equal 7, result["pull_number"]
    assert_equal "squash", result["merge_method"]

    merged = @fake_github_client.merged_pull_requests.sole
    assert_equal "hamajyotan/omochi", merged[:repository]
    assert_equal 7, merged[:pull_number]
    assert_equal "squash", merged[:merge_method]
  end

  test "merges a Pull Request specified by URL in /merge command" do
    quest = start_quest(body: "/merge https://github.com/hamajyotan/omochi/pull/15")
    execution = quest.claim_next_instruction!

    merger = Omochi::GitHub::PullRequestMerger.new(app_client: @fake_github_client)
    result = merger.merge!(execution)

    assert_equal 15, result["pull_number"]
    assert_equal "merge", result["merge_method"]
    assert_equal 1, @fake_github_client.merged_pull_requests.size
  end

  test "raises MergeError when no Pull Request is associated with the Quest" do
    quest = start_quest(body: "/merge")
    execution = quest.claim_next_instruction!

    merger = Omochi::GitHub::PullRequestMerger.new(app_client: @fake_github_client)
    err = assert_raises(Omochi::GitHub::PullRequestMerger::MergeError) do
      merger.merge!(execution)
    end
    assert_includes err.message, "マージ対象の Pull Request が見つかりません"
  end

  test "DockerRunner executes /merge without starting a Docker container" do
    quest = start_quest(body: "Fix typo")
    quest.external_resources.create!(
      platform: "github",
      resource_type: "pull_request",
      scope_key: "hamajyotan/omochi",
      external_id: "1",
      url: "https://github.com/hamajyotan/omochi/pull/1"
    )
    first_exec = quest.claim_next_instruction!
    first_exec.succeed!(result_summary: "Created PR #1")

    quest.receive_instruction!(body: "/merge", source_platform: "slack", enqueue: false)
    merge_exec = quest.claim_next_instruction!

    runner = QuestExecution::DockerRunner.new(
      docker_client: @fake_docker_client,
      workspace_syncer: nil,
      pull_request_merger: Omochi::GitHub::PullRequestMerger.new(app_client: @fake_github_client)
    )
    runner.run(merge_exec)

    merge_exec.reload
    assert merge_exec.succeeded?
    assert_includes merge_exec.result_summary, "Merged Pull Request #1 (merge)"
    assert_includes merge_exec.result_summary, "https://github.com/hamajyotan/omochi/pull/1"
    assert_empty @fake_docker_client.created_containers
  end
end
