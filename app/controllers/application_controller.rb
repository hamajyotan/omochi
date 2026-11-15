class ApplicationController < ActionController::Base
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  before_action :authenticate_user!
  helper_method :current_user, :logged_in?

  private
    def current_user
      session[:current_user]
    end

    def logged_in?
      current_user.present?
    end

    def authenticate_user!
      return if logged_in?

      session[:return_to] = request.fullpath if request.get? && !request.xhr?
      redirect_to login_path, alert: "ログインしてください。"
    end
end
