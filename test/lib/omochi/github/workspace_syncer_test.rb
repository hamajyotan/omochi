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

  test "publish_changes! pushes Agent commit, creates a Pull Request, and links ExternalResource" do
    quest = start_quest(body: "Implement new helper")
    execution = quest.claim_next_instruction!

    workspace_dir = File.join(@tmp_root, "workspace_publish")
    syncer = Omochi::GitHub::WorkspaceSyncer.new(
      app_client: @fake_app_client,
      remote_url_resolver: ->(_repo) { @remote_repo }
    )

    context = syncer.sync!(execution, workspace_dir)

    # Simulate Agent writing files and running `git add . && git commit` inside /workspace
    File.write(File.join(workspace_dir, ".omochi_instruction.json"), '{"test":true}')
    File.write(File.join(workspace_dir, "helper.rb"), "module Helper; end\n")
    system("git", "-C", workspace_dir, "add", ".", exception: true)
    system("git", "-C", workspace_dir, "commit", "-m", "Add Helper module", out: File::NULL, err: File::NULL, exception: true)

    result = syncer.publish_changes!(
      execution,
      workspace_dir,
      git_context: context,
      summary: "Added Helper module as requested."
    )

    assert_equal "created_pr", result["action"]
    assert_equal 101, result["pull_number"]
    assert_equal "https://github.com/hamajyotan/omochi/pull/101", result["url"]
    assert_equal "omochi/#{quest.public_id}", result["branch"]
    assert_equal 1, result["commits_count"]

    # Verify PR was created via AppClient with commit subject and quest marker
    pr_req = @fake_app_client.created_pull_requests.sole
    assert_equal "Add Helper module", pr_req[:title]
    assert_includes pr_req[:body], "Added Helper module as requested."
    assert_includes pr_req[:body], "<!-- omochi:quest=#{quest.public_id} -->"
    assert_equal "omochi/#{quest.public_id}", pr_req[:head]
    assert_equal "main", pr_req[:base]

    # Verify ExternalResource was attached to the Quest
    pr_res = quest.external_resources.find_by(platform: "github", resource_type: "pull_request")
    assert_not_nil pr_res
    assert_equal "101", pr_res.external_id

    # Verify `.omochi_instruction.json` was excluded by `.git/info/exclude` and not committed
    committed_files, _ = Open3.capture2("git", "--git-dir", @remote_repo, "ls-tree", "--name-only", "refs/heads/omochi/#{quest.public_id}")
    assert_includes committed_files.lines.map(&:strip), "helper.rb"
    assert_not_includes committed_files.lines.map(&:strip), ".omochi_instruction.json"
  end

  test "publish_changes! returns nil and does not push when Agent makes no commits" do
    quest = start_quest(body: "Just investigate")
    execution = quest.claim_next_instruction!

    workspace_dir = File.join(@tmp_root, "workspace_no_commit")
    syncer = Omochi::GitHub::WorkspaceSyncer.new(
      app_client: @fake_app_client,
      remote_url_resolver: ->(_repo) { @remote_repo }
    )

    context = syncer.sync!(execution, workspace_dir)
    # Untracked file left behind without git commit
    File.write(File.join(workspace_dir, "scratch.txt"), "notes\n")

    result = syncer.publish_changes!(
      execution,
      workspace_dir,
      git_context: context,
      summary: "Investigated the issue."
    )

    assert_nil result
    assert_empty @fake_app_client.created_pull_requests
  end

  test "detects example/app repository from instruction text, uses its default_branch (develop), and remembers it for follow-up instructions" do
    github_config = Rails.configuration.omochi[:github]
    original_repositories = github_config[:repositories]
    github_config[:repositories] = "hamajyotan/omochi,example/app"

    @fake_app_client.repositories["example/app"] = {
      "full_name" => "example/app",
      "default_branch" => "develop"
    }

    quest = start_quest(body: "app リポジトリに新しい設定ファイルを追加して PR を出して")
    execution = quest.claim_next_instruction!

    workspace_dir = File.join(@tmp_root, "workspace_app")
    syncer = Omochi::GitHub::WorkspaceSyncer.new(
      app_client: @fake_app_client,
      remote_url_resolver: ->(_repo) { @remote_repo }
    )

    context = syncer.sync!(execution, workspace_dir)

    assert_equal "example/app", context["repository"]
    assert_equal "develop", context["base_ref"]

    # Simulate Agent committing a file
    File.write(File.join(workspace_dir, "app.yml"), "env: prod\n")
    system("git", "-C", workspace_dir, "add", "app.yml", exception: true)
    system("git", "-C", workspace_dir, "commit", "-m", "Add app.yml", out: File::NULL, err: File::NULL, exception: true)

    result = syncer.publish_changes!(
      execution,
      workspace_dir,
      git_context: context,
      summary: "Added app.yml to app."
    )

    assert_equal "created_pr", result["action"]
    pr_req = @fake_app_client.created_pull_requests.sole
    assert_equal "example/app", pr_req[:repository]
    assert_equal "develop", pr_req[:base]

    # Follow-up instruction without repeating "app" still targets example/app
    execution.succeed!(result_summary: "Done")
    quest.receive_instruction!(body: "テストも追加して", source_platform: "slack", enqueue: false)
    second_exec = quest.claim_next_instruction!
    second_context = syncer.sync!(second_exec, workspace_dir)
    assert_equal "example/app", second_context["repository"]
  ensure
    github_config[:repositories] = original_repositories if github_config
  end

  test "creates a new branch and new PR when previous PR on the Quest is closed/merged" do
    quest = Quest.create!(title: "Follow-up PR after merge")
    quest.external_resources.create!(
      platform: "github",
      resource_type: "pull_request",
      scope_key: "hamajyotan/omochi",
      external_id: "42",
      url: "https://github.com/hamajyotan/omochi/pull/42"
    )
    quest.receive_instruction!(body: "Add follow-up change", source_platform: "slack", enqueue: false)
    exec = quest.claim_next_instruction!

    @fake_app_client.pull_requests["hamajyotan/omochi#42"] = {
      "number" => 42,
      "state" => "closed",
      "merged" => true,
      "title" => "PR #42",
      "base" => { "ref" => "main", "sha" => "base_sha" },
      "head" => { "ref" => "omochi/#{quest.public_id}", "sha" => "head_sha" }
    }

    syncer = Omochi::GitHub::WorkspaceSyncer.new(
      app_client: @fake_app_client,
      remote_url_resolver: ->(_repo) { @remote_repo }
    )

    workspace_dir = File.join(@tmp_root, "ws_after_merge")
    git_context = syncer.sync!(exec, workspace_dir)

    assert_equal "branch", git_context["mode"]
    assert_equal "omochi/#{quest.public_id}-2", git_context["branch"]

    File.write(File.join(workspace_dir, "followup.txt"), "New change\n")
    system("git", "-C", workspace_dir, "add", "followup.txt", exception: true)
    system("git", "-C", workspace_dir, "commit", "-m", "Follow-up fix", out: File::NULL, err: File::NULL, exception: true)

    result = syncer.publish_changes!(exec, workspace_dir, git_context: git_context, summary: "Added follow-up")
    assert_equal "created_pr", result["action"]
    assert_equal 101, result["pull_number"]
    assert_equal "https://github.com/hamajyotan/omochi/pull/101", result["url"]
    assert_equal "omochi/#{quest.public_id}-2", result["branch"]
    assert_equal [ "omochi" ], @fake_app_client.added_labels.last[:labels]
    assert_equal 101, @fake_app_client.added_labels.last[:issue_number]
  end

  test "handles ASCII-8BIT UTF-8 byte sequences in PR diff without Encoding::UndefinedConversionError" do
    quest = Quest.create!(title: "Japanese PR diff")
    resource = quest.external_resources.create!(
      platform: "github",
      resource_type: "pull_request",
      scope_key: "hamajyotan/omochi",
      external_id: "42",
      url: "https://github.com/hamajyotan/omochi/pull/42"
    )
    quest.receive_instruction!(body: "地域を鳥取市に修正", source_platform: "slack", external_resource: resource, enqueue: false)
    exec = quest.claim_next_instruction!

    @fake_app_client.pull_request_diffs["hamajyotan/omochi#42"] = "+<title>鳥取県米子地域</title>\n".b

    syncer = Omochi::GitHub::WorkspaceSyncer.new(
      app_client: @fake_app_client,
      remote_url_resolver: ->(_repo) { @remote_repo }
    )
    workspace_dir = File.join(@tmp_root, "ws_jp_diff")
    git_context = syncer.sync!(exec, workspace_dir)

    assert_equal "pull_request", git_context["mode"]
    assert_equal true, git_context["checked_out"]
    written_diff = File.read(File.join(workspace_dir, ".omochi_pr.diff"), encoding: Encoding::UTF_8)
    assert_includes written_diff, "鳥取県米子地域"
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
