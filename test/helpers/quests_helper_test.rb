require "test_helper"

class QuestsHelperTest < ActionView::TestCase
  include QuestsHelper

  test "format_time converts UTC timestamp to Tokyo time" do
    utc_time = Time.utc(2026, 11, 15, 8, 30, 0)
    formatted = format_time(utc_time)

    # In Tokyo time (UTC+9), 08:30 UTC is 17:30 JST
    assert_includes formatted, "2026-11-15 17:30:00"
    assert_includes formatted, 'datetime="2026-11-15T08:30:00Z"'
  end

  test "active record default timezone is utc and application timezone is Tokyo" do
    assert_equal "Tokyo", Time.zone.name
    assert_equal :utc, ActiveRecord.default_timezone
  end
end
