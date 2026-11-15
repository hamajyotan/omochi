require "test_helper"

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @skip_default_sign_in = true
  end

  test "unauthenticated user is redirected to login" do
    get root_path
    assert_redirected_to login_path
  end

  test "login page displays Sign in with GitHub button" do
    client = Omochi::GitHub::OAuthClient.new(
      client_id: "fake_client_id",
      client_secret: "fake_secret"
    )
    Omochi::GitHub.oauth_client_factory = -> { client }

    get login_path
    assert_response :success
    assert_select "a[href^='https://github.com/login/oauth/authorize']"
    assert_select ".btn--github", text: /Sign in with GitHub/
  end

  test "callback with invalid state redirects to login with alert" do
    get auth_github_callback_path, params: { code: "any_code", state: "tampered_state" }
    assert_redirected_to login_path
    assert_equal "認証セッションの検証に失敗しました。もう一度お試しください。", flash[:alert]
  end

  test "callback with authorized user logs in successfully" do
    fake_response = Struct.new(:code, :body)

    requester = ->(uri, method:, headers:, body:) do
      if uri.path.include?("access_token")
        fake_response.new("200", { access_token: "gho_test_token" }.to_json)
      elsif uri.path.include?("user")
        fake_response.new("200", { login: "hamajyotan", name: "Takashi", avatar_url: "https://example.com/avatar.png" }.to_json)
      end
    end

    client = Omochi::GitHub::OAuthClient.new(
      client_id: "fake_id",
      client_secret: "fake_secret",
      http_requester: requester
    )
    Omochi::GitHub.oauth_client_factory = -> { client }

    # First visit login to get state stored in session
    get login_path
    state = session[:oauth_state]
    assert state.present?

    # Simulate callback from GitHub
    get auth_github_callback_path, params: { code: "valid_code", state: state }

    assert_redirected_to root_path
    assert_equal "hamajyotan", session[:current_user]["login"]
    assert_equal "Takashi", session[:current_user]["name"]
  end

  test "callback with unauthorized user renders 403 forbidden" do
    fake_response = Struct.new(:code, :body)

    requester = ->(uri, method:, headers:, body:) do
      if uri.path.include?("access_token")
        fake_response.new("200", { access_token: "gho_test_token" }.to_json)
      elsif uri.path.include?("user")
        fake_response.new("200", { login: "unauthorized_user", name: "Unknown" }.to_json)
      end
    end

    client = Omochi::GitHub::OAuthClient.new(
      client_id: "fake_id",
      client_secret: "fake_secret",
      http_requester: requester
    )
    Omochi::GitHub.oauth_client_factory = -> { client }

    # Configure allowed_users setting
    orig = Rails.configuration.omochi[:github][:allowed_users]
    Rails.configuration.omochi[:github][:allowed_users] = "hamajyotan"

    begin
      get login_path
      state = session[:oauth_state]

      get auth_github_callback_path, params: { code: "valid_code", state: state }

      assert_response :forbidden
      assert_select "h1", "Access Denied"
      assert_select "strong", text: "@unauthorized_user"
      assert_nil session[:current_user]
    ensure
      Rails.configuration.omochi[:github][:allowed_users] = orig
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
