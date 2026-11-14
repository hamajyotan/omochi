require "test_helper"

class Omochi::SettingsTest < ActiveSupport::TestCase
  setup { @original = Rails.configuration.omochi }
  teardown { Rails.configuration.omochi = @original }

  test "fetch! raises a clear error for missing settings" do
    Rails.configuration.omochi = { slack: { bot_token: "" } }

    error = assert_raises(Omochi::Settings::MissingSetting) { Omochi::Settings.fetch!(:slack, :bot_token) }
    assert_includes error.message, "slack.bot_token"
    assert_nil Omochi::Settings.dig(:slack, :bot_token)
  end

  test "fetch! returns present values" do
    Rails.configuration.omochi = { slack: { bot_token: "xoxb-test" } }

    assert_equal "xoxb-test", Omochi::Settings.fetch!(:slack, :bot_token)
  end

  test "config/omochi.yml is loaded" do
    assert_respond_to @original, :dig
    assert @original.key?(:slack)
  end
end
