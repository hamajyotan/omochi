# Read access to config/omochi.yml.
#
#   Omochi::Settings.fetch!(:slack, :bot_token) # raises if missing / blank
#   Omochi::Settings.dig(:slack, :bot_token)    # nil if missing
#
# Settings are only required by the component that uses them, so a missing Slack
# token does not prevent the Dashboard or the worker from booting.
module Omochi
  module Settings
    class MissingSetting < StandardError; end

    module_function

    def dig(*keys)
      Rails.configuration.omochi.dig(*keys.map(&:to_sym)).presence
    end

    def fetch!(*keys)
      dig(*keys) || raise(MissingSetting, "Missing omochi setting: #{keys.join('.')} (see .env.example)")
    end
  end
end
