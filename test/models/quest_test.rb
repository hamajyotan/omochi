require "test_helper"

class QuestTest < ActiveSupport::TestCase
  test "assigns a qst_ prefixed UUIDv7 public id on create" do
    quest = Quest.create!(title: "Write docs")

    assert_match Quest::PUBLIC_ID_FORMAT, quest.public_id
    assert_not_equal quest.id.to_s, quest.public_id
  end

  test "public ids are unique" do
    ids = Array.new(100) { Quest.generate_public_id }

    assert_equal 100, ids.uniq.size
    assert ids.all? { |id| id.match?(Quest::PUBLIC_ID_FORMAT) }
  end

  test "uses the public id in URLs" do
    quest = Quest.create!(title: "x")

    assert_equal quest.public_id, quest.to_param
    assert_equal quest, Quest.find_by_public_id!(quest.public_id)
  end

  test "public id cannot be changed after creation" do
    quest = Quest.create!(title: "x")
    original = quest.public_id

    assert_raises(ActiveRecord::ActiveRecordError) { quest.update!(public_id: Quest.generate_public_id) }
    assert_equal original, quest.reload.public_id
  end

  test "rejects malformed public ids" do
    quest = Quest.new(title: "x", public_id: "C0123SLACK")

    assert_not quest.valid?
    assert quest.errors.of_kind?(:public_id, :invalid)
  end

  test "requires a title and starts pending" do
    assert_not Quest.new.valid?
    assert Quest.create!(title: "x").pending?
  end

  test "rejects unknown statuses" do
    quest = Quest.new(title: "x", status: "bogus")

    assert_not quest.valid?
  end
end
