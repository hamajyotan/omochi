require "test_helper"

class QuestExecutionEventTest < ActiveSupport::TestCase
  test "handles multibyte UTF-8 input correctly even from binary stream" do
    raw_binary = %Q({"type":"completed","summary":"初めての本番 Quest テスト"}\n).b
    parsed = QuestExecutionEvent.parse_line(raw_binary)
    assert_equal "completed", parsed[:event_type]
    assert_equal "初めての本番 Quest テスト", parsed[:message]
  end

  test "parses structured JSONL events on stdout" do
    parsed = QuestExecutionEvent.parse_line('{"type":"progress","message":"Step 1","data":{"step":1}}')

    assert_equal "progress", parsed[:event_type]
    assert_equal "Step 1", parsed[:message]
    assert_equal({ "data" => { "step" => 1 } }, parsed[:payload])
  end

  test "extracts summary or error when message is omitted" do
    completed = QuestExecutionEvent.parse_line('{"type":"completed","summary":"All done"}')
    failed = QuestExecutionEvent.parse_line('{"type":"failed","error":"Boom"}')

    assert_equal "completed", completed[:event_type]
    assert_equal "All done", completed[:message]
    assert_equal "failed", failed[:event_type]
    assert_equal "Boom", failed[:message]
  end

  test "wraps non-JSON or unknown event types as log events" do
    plain = QuestExecutionEvent.parse_line("Hello world\n", stream: "stdout")
    unknown = QuestExecutionEvent.parse_line('{"type":"unknown","message":"x"}', stream: "stdout")
    malformed = QuestExecutionEvent.parse_line("{broken json", stream: "stdout")
    stderr_json = QuestExecutionEvent.parse_line('{"type":"completed","summary":"no"}', stream: "stderr")

    assert_equal "log", plain[:event_type]
    assert_equal "Hello world", plain[:message]
    assert_equal "log", unknown[:event_type]
    assert_equal "log", malformed[:event_type]
    assert_equal true, malformed[:payload]["raw"]
    assert_equal "log", stderr_json[:event_type]
    assert_equal "stderr", stderr_json[:payload]["stream"]
  end

  test "truncates oversized lines safely" do
    long_line = "x" * (QuestExecutionEvent::MAX_LINE_BYTES + 500)
    parsed = QuestExecutionEvent.parse_line(long_line)

    assert_equal "log", parsed[:event_type]
    assert_equal true, parsed[:payload]["truncated"]
    assert_operator parsed[:message].length, :<=, QuestExecutionEvent::MAX_MESSAGE_LENGTH
  end

  test "records sequential immutable events on an execution" do
    quest = start_quest
    execution = quest.claim_next_instruction!

    e1 = execution.record_output_line!('{"type":"started","message":"go"}')
    e2 = execution.record_output_line!("plain line")

    assert_equal [ 1, 2 ], [ e1.sequence, e2.sequence ]
    assert_equal %w[started log], execution.events.pluck(:event_type)
    assert_raises(ActiveRecord::ActiveRecordError) { e1.update!(message: "tampered") }
  end
end
