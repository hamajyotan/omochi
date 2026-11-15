require "test_helper"
require "tmpdir"

class Omochi::GitHub::WorkspaceSyncerTest < ActiveSupport::TestCase
  setup do
    @fake_app_client = Omochi::GitHub::FakeAppClient.new
    @tmp_root = Dir.mktmpdir("omochi_git_test")
    @remote_repo = File.join(@tmp_root, "remote.git")
    setup_local_remote_repo(@remote_repo)
  end

  teardown do
    FileUtils.rm_rf(@tmp_root) if @tmp_root && File.exist?(@tmp_root)
  end

  test "syncs a Pull Request into workspace, writes .omochi_pr.diff, and leaves no credentials in .git/config" do
    quest = Quest.create!(title: "Review PR #42")
    resource = quest.external_resources.create!(
      platform: "github",
      resource_type: "pull_request",
      scope_key: "hamajyotan/omochi",
      external_id: "42",
      url: "https://github.com/hamajyotan/omochi/pull/42"
    )
    quest.receive_instruction!(
      body: "/review",
      source_platform: "github",
      source_event_id: "deliv_42",
      external_resource: resource,
      enqueue: false
    )
    execution = quest.claim_next_instruction!

    workspace_dir = File.join(@tmp_root, "workspace_pr")
    syncer = Omochi::GitHub::WorkspaceSyncer.new(
      app_client: @fake_app_client,
      remote_url_resolver: ->(_repo) { @remote_repo }
    )

    context = syncer.sync!(execution, workspace_dir)

    assert_equal "hamajyotan/omochi", context["repository"]
    assert_equal "pull_request", context["mode"]
    assert_equal 42, context["pull_number"]
    assert_equal true, context["checked_out"]
    assert_equal ".omochi_pr.diff", context["diff_file"]

    # PR branch file from refs/pull/42/head is checked out
    assert_equal "PR 42 feature content\n", File.read(File.join(workspace_dir, "feature.txt"))

    # Unified diff file is written
    diff_content = File.read(File.join(workspace_dir, ".omochi_pr.diff"))
    assert_includes diff_content, "Added line in PR #42"

    # Security invariant: .git/config must never contain any installation token or Authorization header
    git_config = File.read(File.join(workspace_dir, ".git", "config"))
    assert_not_includes git_config, "ghs_fake_token"
    assert_not_includes git_config, "x-access-token"
    assert_not_includes git_config, "extraHeader"
  end

  test "syncs default branch for non-PR quests into omochi/<quest_public_id> branch" do
    quest = start_quest(body: "Check main branch code")
    execution = quest.claim_next_instruction!

    workspace_dir = File.join(@tmp_root, "workspace_branch")
    syncer = Omochi::GitHub::WorkspaceSyncer.new(
      app_client: @fake_app_client,
      remote_url_resolver: ->(_repo) { @remote_repo }
    )

    context = syncer.sync!(execution, workspace_dir)

    assert_equal "hamajyotan/omochi", context["repository"]
    assert_equal "branch", context["mode"]
    assert_equal "omochi/#{quest.public_id}", context["branch"]
    assert_equal true, context["checked_out"]
    assert_equal "Hello from main\n", File.read(File.join(workspace_dir, "README.md"))
  end

  test "returns nil when GitHub App credentials are not configured" do
    quest = start_quest(body: "No github config")
    execution = quest.claim_next_instruction!
    workspace_dir = File.join(@tmp_root, "workspace_noop")

    orig_app_id = Rails.configuration.omochi[:github][:app_id]
    Rails.configuration.omochi[:github][:app_id] = nil
    begin
      syncer = Omochi::GitHub::WorkspaceSyncer.new
      assert_nil syncer.sync!(execution, workspace_dir)
    ensure
      Rails.configuration.omochi[:github][:app_id] = orig_app_id
    end
  end

  private
    def setup_local_remote_repo(bare_path)
      work_path = File.join(@tmp_root, "seed_work")
      FileUtils.mkdir_p(bare_path)
      FileUtils.mkdir_p(work_path)

      system("git", "init", "--bare", bare_path, out: File::NULL, err: File::NULL, exception: true)
      system("git", "-C", work_path, "init", out: File::NULL, err: File::NULL, exception: true)
      system("git", "-C", work_path, "config", "user.email", "test@example.com", exception: true)
      system("git", "-C", work_path, "config", "user.name", "Test", exception: true)

      File.write(File.join(work_path, "README.md"), "Hello from main\n")
      system("git", "-C", work_path, "add", "README.md", exception: true)
      system("git", "-C", work_path, "commit", "-m", "Initial commit", out: File::NULL, err: File::NULL, exception: true)
      system("git", "-C", work_path, "push", bare_path, "HEAD:refs/heads/main", out: File::NULL, err: File::NULL, exception: true)
      system("git", "--git-dir", bare_path, "symbolic-ref", "HEAD", "refs/heads/main", exception: true)

      File.write(File.join(work_path, "feature.txt"), "PR 42 feature content\n")
      system("git", "-C", work_path, "add", "feature.txt", exception: true)
      system("git", "-C", work_path, "commit", "-m", "Add feature 42", out: File::NULL, err: File::NULL, exception: true)
      system("git", "-C", work_path, "push", bare_path, "HEAD:refs/pull/42/head", out: File::NULL, err: File::NULL, exception: true)
    end
end
