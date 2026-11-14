require "test_helper"

class ExternalResourceTest < ActiveSupport::TestCase
  setup { @quest = Quest.create!(title: "x") }

  def attributes(**overrides)
    { platform: "slack", resource_type: "thread", scope_key: "T001/C001", external_id: "1700000000.000100" }.merge(overrides)
  end

  test "a quest can have multiple external resources" do
    @quest.external_resources.create!(attributes)
    @quest.external_resources.create!(attributes(platform: "github", resource_type: "issue", scope_key: "acme/app", external_id: "12"))

    assert_equal 2, @quest.external_resources.count
  end

  test "identity is unique within platform, type and scope" do
    @quest.external_resources.create!(attributes)
    other = Quest.create!(title: "y")

    assert_not other.external_resources.build(attributes).valid?
    assert other.external_resources.build(attributes(scope_key: "T002/C001")).valid?
  end

  test "database enforces identity uniqueness" do
    @quest.external_resources.create!(attributes)

    assert_raises(ActiveRecord::RecordNotUnique) do
      ExternalResource.new(attributes.merge(quest: @quest)).save!(validate: false)
    end
  end

  test "identity lookup" do
    resource = @quest.external_resources.create!(attributes)

    assert_equal resource, ExternalResource.identity(**attributes)
  end

  test "rejects unknown platforms" do
    assert_not @quest.external_resources.build(attributes(platform: "irc")).valid?
  end
end
