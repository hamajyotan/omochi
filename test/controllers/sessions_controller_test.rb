require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @skip_default_sign_in = true
    @orig_factory = Omochi::Slack.oauth_client_factory
  end

  teardown do
    Omochi::Slack.oauth_client_factory = @orig_factory
  end

  test "unauthenticated user is redirected to login" do
    get root_path
    assert_redirected_to login_path
  end

  test "login page displays Sign in with Slack button" do
    client = Omochi::Slack::OAuthClient.new(
      client_id: "fake_client_id",
      client_secret: "fake_secret",
      team_id: "T012345"
    )
    Omochi::Slack.oauth_client_factory = -> { client }

    get login_path
    assert_response :success
    assert_select "a[href^='https://slack.com/openid/connect/authorize']"
    assert_select ".btn--slack", text: /Sign in with Slack/
  end

  test "callback with invalid state redirects to login with alert" do
    get auth_slack_callback_path, params: { code: "any_code", state: "tampered_state" }
    assert_redirected_to login_path
    assert_equal "認証セッションの検証に失敗しました。もう一度お試しください。", flash[:alert]
  end

  test "callback with authorized workspace member logs in successfully" do
    fake_response = Struct.new(:code, :body)

    requester = ->(uri, method:, headers:, body:) do
      if uri.path.include?("openid.connect.token")
        fake_response.new("200", { ok: true, access_token: "xoxp_test_token" }.to_json)
      elsif uri.path.include?("openid.connect.userInfo")
        fake_response.new("200", {
          "ok" => true,
          "sub" => "U012345",
          "https://slack.com/team_id" => "T012345",
          "name" => "Takashi",
          "email" => "takashi@example.com",
          "picture" => "https://example.com/avatar.png"
        }.to_json)
      end
    end

    client = Omochi::Slack::OAuthClient.new(
      client_id: "fake_id",
      client_secret: "fake_secret",
      team_id: "T012345",
      http_requester: requester
    )
    Omochi::Slack.oauth_client_factory = -> { client }

    orig_team_id = Rails.configuration.omochi[:slack][:team_id]
    Rails.configuration.omochi[:slack][:team_id] = "T012345"

    begin
      get login_path
      state = session[:oauth_state]
      assert state.present?

      get auth_slack_callback_path, params: { code: "valid_code", state: state }

      assert_redirected_to root_path
      assert_equal "takashi@example.com", session[:current_user]["login"]
      assert_equal "U012345", session[:current_user]["slack_user_id"]
      assert_equal "T012345", session[:current_user]["team_id"]
      assert_equal "Takashi", session[:current_user]["name"]
    ensure
      Rails.configuration.omochi[:slack][:team_id] = orig_team_id
    end
  end

  test "callback from different workspace renders 403 forbidden" do
    fake_response = Struct.new(:code, :body)

    requester = ->(uri, method:, headers:, body:) do
      if uri.path.include?("openid.connect.token")
        fake_response.new("200", { ok: true, access_token: "xoxp_test_token" }.to_json)
      elsif uri.path.include?("openid.connect.userInfo")
        fake_response.new("200", {
          "ok" => true,
          "sub" => "U999999",
          "https://slack.com/team_id" => "T_OTHER_WORKSPACE",
          "name" => "Outsider"
        }.to_json)
      end
    end

    client = Omochi::Slack::OAuthClient.new(
      client_id: "fake_id",
      client_secret: "fake_secret",
      http_requester: requester
    )
    Omochi::Slack.oauth_client_factory = -> { client }

    orig_team_id = Rails.configuration.omochi[:slack][:team_id]
    Rails.configuration.omochi[:slack][:team_id] = "T012345"

    begin
      get login_path
      state = session[:oauth_state]

      get auth_slack_callback_path, params: { code: "valid_code", state: state }

      assert_response :forbidden
      assert_select "h1", "Access Denied"
      assert_select "strong", text: "Outsider"
      assert_nil session[:current_user]
    ensure
      Rails.configuration.omochi[:slack][:team_id] = orig_team_id
    end
  end

  test "callback with user not in allowed_users renders 403 forbidden" do
    fake_response = Struct.new(:code, :body)

    requester = ->(uri, method:, headers:, body:) do
      if uri.path.include?("openid.connect.token")
        fake_response.new("200", { ok: true, access_token: "xoxp_test_token" }.to_json)
      elsif uri.path.include?("openid.connect.userInfo")
        fake_response.new("200", {
          "ok" => true,
          "sub" => "U_NOT_ALLOWED",
          "https://slack.com/team_id" => "T012345",
          "name" => "RestrictedUser"
        }.to_json)
      end
    end

    client = Omochi::Slack::OAuthClient.new(
      client_id: "fake_id",
      client_secret: "fake_secret",
      http_requester: requester
    )
    Omochi::Slack.oauth_client_factory = -> { client }

    orig_team_id = Rails.configuration.omochi[:slack][:team_id]
    orig_allowed = Rails.configuration.omochi[:slack][:allowed_users]
    Rails.configuration.omochi[:slack][:team_id] = "T012345"
    Rails.configuration.omochi[:slack][:allowed_users] = "U012345"

    begin
      get login_path
      state = session[:oauth_state]

      get auth_slack_callback_path, params: { code: "valid_code", state: state }

      assert_response :forbidden
      assert_select "h1", "Access Denied"
      assert_nil session[:current_user]
    ensure
      Rails.configuration.omochi[:slack][:team_id] = orig_team_id
      Rails.configuration.omochi[:slack][:allowed_users] = orig_allowed
    end
  end

  test "logout clears session and redirects to login" do
    sign_in_as("hamajyotan")

    delete logout_path
    assert_redirected_to login_path
    assert_nil session[:current_user]
    assert_equal "ログアウトしました。", flash[:notice]
  end
end
