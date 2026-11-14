# Processes incoming Slack Socket Mode envelopes (`events_api` / `app_mention`).
#
# Ordering guarantee (docs/decisions/0006-slack-socket-mode-and-notifications.md):
# `handle_envelope` synchronously persists the Quest, ExternalResource, and
# QuestInstruction BEFORE returning so the caller (`SocketClient`) only sends
# the Socket Mode ACK after the instruction is durably stored in SQLite.
module Omochi
  module Slack
    class EventHandler
      MENTION_PREFIX = /\A(?:\s*<@[A-Z0-9]+>\s*)+/
      IGNORED_SUBTYPES = %w[bot_message message_changed message_deleted message_replied].freeze

      Result = Data.define(:status, :instruction, :created_quest, :duplicate)

      def handle_envelope(envelope)
        return Result.new(status: :ignored, instruction: nil, created_quest: false, duplicate: false) unless envelope.is_a?(Hash)
        return Result.new(status: :ignored, instruction: nil, created_quest: false, duplicate: false) unless envelope["type"] == "events_api"

        payload = envelope["payload"]
        return Result.new(status: :ignored, instruction: nil, created_quest: false, duplicate: false) unless payload.is_a?(Hash)

        handle_event_payload(payload)
      end

      def handle_event_payload(payload)
        event = payload["event"]
        return ignored unless valid_app_mention?(event)

        event_id = payload["event_id"].to_s.strip
        team_id = (payload["team_id"] || event["team"]).to_s.strip
        channel = event["channel"].to_s.strip
        ts = event["ts"].to_s.strip
        thread_ts = (event["thread_ts"].presence || ts).to_s.strip
        return ignored if event_id.empty? || team_id.empty? || channel.empty? || thread_ts.empty?

        existing = QuestInstruction.find_duplicate(source_platform: "slack", source_event_id: event_id)
        if existing
          return Result.new(status: :duplicate, instruction: existing, created_quest: false, duplicate: true)
        end

        body = extract_instruction_body(event["text"])
        scope_key = "#{team_id}/#{channel}"
        resource = ExternalResource.identity(
          platform: "slack",
          resource_type: "thread",
          scope_key: scope_key,
          external_id: thread_ts
        )

        if resource
          instruction = resource.quest.receive_instruction!(
            body: body,
            source_platform: "slack",
            source_event_id: event_id,
            external_resource: resource,
            enqueue: false
          )
          enqueue_receipt_notification(instruction, created_quest: false)
          instruction.quest.enqueue_processing
          Result.new(status: :accepted, instruction: instruction, created_quest: false, duplicate: false)
        else
          instruction = Quest.start!(
            title: build_title(body),
            body: body,
            source_platform: "slack",
            source_event_id: event_id,
            external_resource: {
              platform: "slack",
              resource_type: "thread",
              scope_key: scope_key,
              external_id: thread_ts
            },
            enqueue: false
          )
          enqueue_receipt_notification(instruction, created_quest: true)
          instruction.quest.enqueue_processing
          Result.new(status: :accepted, instruction: instruction, created_quest: true, duplicate: false)
        end
      end

      private
        def ignored
          Result.new(status: :ignored, instruction: nil, created_quest: false, duplicate: false)
        end

        def valid_app_mention?(event)
          return false unless event.is_a?(Hash)
          return false unless event["type"] == "app_mention"
          return false if event["bot_id"].present? || event["bot_profile"].present?
          return false if IGNORED_SUBTYPES.include?(event["subtype"].to_s)

          true
        end

        def extract_instruction_body(raw_text)
          cleaned = raw_text.to_s.sub(MENTION_PREFIX, "").strip
          cleaned = raw_text.to_s.strip if cleaned.empty?
          cleaned.presence || "(empty mention)"
        end

        def build_title(body)
          first_line = body.lines.first.to_s.strip
          first_line.truncate(80).presence || "Slack Quest"
        end

        def enqueue_receipt_notification(instruction, created_quest:)
          resource = instruction.external_resource
          return unless resource

          quest_id = instruction.quest.public_id
          text =
            if created_quest
              "🍡 Quest created: `#{quest_id}` (Instruction ##{instruction.sequence} queued)"
            else
              "🍡 Instruction ##{instruction.sequence} queued for `#{quest_id}`"
            end
          SlackNotificationJob.perform_later(resource, text)
        end
    end
  end
end
