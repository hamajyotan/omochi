# Processes incoming Slack Socket Mode envelopes (`events_api` / `app_mention`).
#
# Ordering guarantee (docs/decisions/0006-slack-socket-mode-and-notifications.md):
# `handle_envelope` synchronously persists the Quest, ExternalResource, and
# QuestInstruction BEFORE returning so the caller (`SocketClient`) only sends
# the Socket Mode ACK after the instruction is durably stored in SQLite.
module Omochi
  module Slack
    class EventHandler
      MENTION_PREFIX = /\A(?:\s*<@[A-Z0-9_]+>\s*)+/
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
        return ignored unless valid_event?(event, payload)

        event_id = payload["event_id"].to_s.strip
        team_id = (payload["team_id"] || event["team"]).to_s.strip
        channel = event["channel"].to_s.strip
        ts = event["ts"].to_s.strip
        thread_ts = (event["thread_ts"].presence || ts).to_s.strip
        return ignored if event_id.empty? || team_id.empty? || channel.empty? || thread_ts.empty?

        allowed_team_id = Omochi::Settings.dig(:slack, :team_id).to_s.strip
        return ignored if allowed_team_id.present? && team_id != allowed_team_id

        scope_key = "#{team_id}/#{channel}"
        resource = ExternalResource.identity(
          platform: "slack",
          resource_type: "thread",
          scope_key: scope_key,
          external_id: thread_ts
        )

        # Thread replies without @omochi (`type: "message"`) only apply to threads
        # that are already associated with an existing Quest.
        return ignored if event["type"] == "message" && resource.nil?

        existing = QuestInstruction.find_duplicate(source_platform: "slack", source_event_id: event_id)
        if existing
          return Result.new(status: :duplicate, instruction: existing, created_quest: false, duplicate: true)
        end

        body = extract_instruction_body(event["text"])

        if resource
          instruction = resource.quest.receive_instruction!(
            body: body,
            source_platform: "slack",
            source_event_id: event_id,
            external_resource: resource,
            metadata: { "slack_message_ts" => ts },
            enqueue: false
          )
          enqueue_receipt_reaction(instruction)
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
            metadata: { "slack_message_ts" => ts },
            enqueue: false
          )
          enqueue_receipt_reaction(instruction)
          instruction.quest.enqueue_processing
          Result.new(status: :accepted, instruction: instruction, created_quest: true, duplicate: false)
        end
      end

      private
        def ignored
          Result.new(status: :ignored, instruction: nil, created_quest: false, duplicate: false)
        end

        def valid_event?(event, payload)
          return false unless event.is_a?(Hash)
          return false if event["bot_id"].present? || event["bot_profile"].present?
          return false if IGNORED_SUBTYPES.include?(event["subtype"].to_s)

          case event["type"]
          when "app_mention"
            true
          when "message"
            event["subtype"].blank? &&
              event["thread_ts"].present? &&
              !mentions_bot?(event, payload)
          else
            false
          end
        end

        def mentions_bot?(event, payload)
          text = event["text"].to_s
          bot_ids = extract_bot_user_ids(payload)
          if bot_ids.any?
            bot_ids.any? { |uid| text.include?("<@#{uid}>") }
          else
            text.match?(MENTION_PREFIX)
          end
        end

        def extract_bot_user_ids(payload)
          ids = []
          if payload["authorizations"].is_a?(Array)
            payload["authorizations"].each do |auth|
              ids << auth["user_id"].to_s if auth.is_a?(Hash) && auth["user_id"].present?
            end
          end
          if payload["authed_users"].is_a?(Array)
            payload["authed_users"].each { |uid| ids << uid.to_s if uid.present? }
          end
          ids.uniq
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

        def enqueue_receipt_reaction(instruction)
          resource = instruction.external_resource
          return unless resource

          SlackReactionJob.perform_later(resource, instruction.slack_message_ts, "add", "eyes")
        end
    end
  end
end
