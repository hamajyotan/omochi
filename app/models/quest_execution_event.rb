# A structured event emitted by an Agent Container during a QuestExecution.
#
# Agent stdout is parsed line-by-line as JSON Lines (JSONL). Non-JSON lines or
# stderr lines are safely wrapped as `log` events so output is never silently
# lost.
class QuestExecutionEvent < ApplicationRecord
  EVENT_TYPES = %w[started progress log result completed failed].freeze
  MAX_LINE_BYTES = 16_384
  MAX_MESSAGE_LENGTH = 4_000

  belongs_to :execution, class_name: "QuestExecution", foreign_key: :quest_execution_id, inverse_of: :events

  validates :sequence, presence: true, uniqueness: { scope: :quest_execution_id }
  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :occurred_at, presence: true

  attr_readonly :sequence, :event_type, :message, :payload, :occurred_at, :quest_execution_id

  scope :in_order, -> { order(:sequence) }

  # Parses one line of stdout/stderr from the Agent Container into attributes
  # suitable for `QuestExecution#record_event!`.
  def self.parse_line(raw_line, stream: "stdout")
    line = raw_line.to_s.dup.force_encoding(Encoding::UTF_8).scrub.chomp
    truncated = line.bytesize > MAX_LINE_BYTES
    line = line.byteslice(0, MAX_LINE_BYTES).scrub if truncated

    if stream == "stdout" && line.start_with?("{")
      parsed = JSON.parse(line)
      if parsed.is_a?(Hash) && EVENT_TYPES.include?(parsed["type"])
        return normalize_structured_event(parsed, truncated:)
      end
    end

    {
      event_type: "log",
      message: line.truncate(MAX_MESSAGE_LENGTH),
      payload: { "stream" => stream, "truncated" => truncated }.compact
    }
  rescue JSON::ParserError
    {
      event_type: "log",
      message: line.truncate(MAX_MESSAGE_LENGTH),
      payload: { "stream" => stream, "raw" => true, "truncated" => truncated }.compact
    }
  end

  def self.normalize_structured_event(hash, truncated: false)
    type = hash["type"]
    message = (hash["message"] || hash["summary"] || hash["error"]).to_s.truncate(MAX_MESSAGE_LENGTH).presence
    payload = hash.except("type", "message")
    payload["truncated"] = true if truncated

    {
      event_type: type,
      message: message,
      payload: payload
    }
  end
  private_class_method :normalize_structured_event
end
