class SessionsController < ApplicationController
  skip_before_action :authenticate_user!, only: [ :new, :callback, :destroy, :test_sign_in ]

  def new
    if logged_in?
      redirect_to root_path
      return
    end

    state = SecureRandom.hex(16)
    session[:oauth_state] = state
    redirect_uri = auth_github_callback_url
    client = Omochi::GitHub.build_oauth_client
    @authorize_url = client.authorize_url(state: state, redirect_uri: redirect_uri)
  rescue StandardError => e
    @authorize_url = nil
    @error_message = e.message
  end

  def callback
    expected_state = session.delete(:oauth_state)
    received_state = params[:state]

    if expected_state.blank? || received_state != expected_state
      redirect_to login_path, alert: "認証セッションの検証に失敗しました。もう一度お試しください。"
      return
    end

    code = params[:code]
    if code.blank?
      redirect_to login_path, alert: "GitHub 認証コードを取得できませんでした。"
      return
    end

    client = Omochi::GitHub.build_oauth_client
    redirect_uri = auth_github_callback_url
    token = client.exchange_code(code: code, redirect_uri: redirect_uri)
    user_info = client.fetch_user(token)

    login = user_info["login"].to_s
    allowed_users = Omochi::Settings.dig(:github, :allowed_users).to_s.split(",").map(&:strip).map(&:downcase)

    if allowed_users.present? && !allowed_users.include?(login.downcase)
      reset_session
      render :forbidden, status: :forbidden, locals: { login: login }
      return
    end

    return_to = session[:return_to]
    reset_session
    session[:current_user] = {
      "login" => login,
      "name" => user_info["name"].presence || login,
      "avatar_url" => user_info["avatar_url"]
    }

    redirect_to return_to.presence || root_path, notice: "@#{login} としてログインしました。"
  rescue Omochi::GitHub::OAuthClient::AuthenticationError => e
    redirect_to login_path, alert: "GitHub 認証に失敗しました: #{e.message}"
  rescue StandardError => e
    Rails.error.report(e)
    redirect_to login_path, alert: "認証処理中にエラーが発生しました。"
  end

  def destroy
    reset_session
    redirect_to login_path, notice: "ログアウトしました。"
  end

  if Rails.env.test?
    def test_sign_in
      login = params[:login].presence || "hamajyotan"
      session[:current_user] = {
        "login" => login,
        "name" => params[:name].presence || login,
        "avatar_url" => "https://avatars.githubusercontent.com/u/12345"
      }
      head :ok
    end
  end
end
