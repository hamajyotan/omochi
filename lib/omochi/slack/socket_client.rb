require "json"
require "openssl"
require "socket"
require "uri"
require "websocket"

# Slack Socket Mode client (`omochi-socket`).
#
# Connects to the WSS endpoint returned by `apps.connections.open`, processes
# incoming envelopes via `Omochi::Slack::EventHandler`, and only sends the
# `{ "envelope_id": ... }` acknowledgement AFTER the handler has durably
# persisted the Quest / QuestInstruction in SQLite.
module Omochi
  module Slack
    class SocketClient
      RECONNECT_DELAY_SECONDS = 2.0

      def initialize(
        web_client: Omochi::Slack.build_web_client,
        event_handler: EventHandler.new,
        logger: Rails.logger
      )
        @web_client = web_client
        @event_handler = event_handler
        @logger = logger
        @stopped = false
      end

      def stop
        @stopped = true
      end

      def stopped?
        @stopped
      end

      # Runs the reconnect loop until `stop` is called.
      def run(reconnect_delay: RECONNECT_DELAY_SECONDS)
        until stopped?
          begin
            wss_url = @web_client.open_socket_connection
            run_session(wss_url)
          rescue StandardError => e
            Rails.error.report(e)
            @logger&.error("[omochi-socket] connection error: #{e.class}: #{e.message}")
            sleep(reconnect_delay) unless stopped? && reconnect_delay.positive?
          end
        end
      end

      # Processes a single JSON message string from Slack Socket Mode and calls
      # `send_text` with the JSON ACK payload when `envelope_id` is present.
      # Returns `:disconnect` if Slack requested a reconnect, `:handled`
      # otherwise.
      def process_raw_message(raw_json, &send_text)
        envelope = JSON.parse(raw_json.to_s)
        return :ignored unless envelope.is_a?(Hash)

        if envelope["type"] == "disconnect"
          @logger&.info("[omochi-socket] disconnect requested by Slack (#{envelope['reason']})")
          return :disconnect
        end

        # Persist Quest / Instruction BEFORE sending the ACK so Slack will
        # redeliver the envelope if our process crashes mid-handling.
        @event_handler.handle_envelope(envelope)

        if (envelope_id = envelope["envelope_id"].presence)
          send_text&.call(JSON.generate(envelope_id: envelope_id))
        end

        :handled
      rescue JSON::ParserError => e
        @logger&.warn("[omochi-socket] ignoring malformed JSON frame: #{e.message}")
        :ignored
      end

      private
        def run_session(wss_url)
          uri = URI.parse(wss_url)
          tcp = TCPSocket.new(uri.host, uri.port || 443)
          ssl_ctx = OpenSSL::SSL::SSLContext.new
          ssl_ctx.set_params(verify_mode: OpenSSL::SSL::VERIFY_PEER)
          ssl = OpenSSL::SSL::SSLSocket.new(tcp, ssl_ctx)
          ssl.hostname = uri.host
          ssl.sync_close = true
          ssl.connect

          perform_handshake!(ssl, wss_url)
          incoming = WebSocket::Frame::Incoming::Client.new(version: 13)

          until stopped?
            ready = IO.select([ ssl ], nil, nil, 1.0)
            next unless ready

            chunk = ssl.readpartial(4096)
            incoming << chunk
            while (frame = incoming.next)
              case frame.type
              when :text
                result = process_raw_message(frame.data) do |ack_json|
                  write_frame(ssl, ack_json, :text)
                end
                return if result == :disconnect
              when :ping
                write_frame(ssl, frame.data, :pong)
              when :close
                return
              end
            end
          end
        rescue EOFError
          nil
        ensure
          ssl&.close rescue nil
        end

        def perform_handshake!(io, url)
          handshake = WebSocket::Handshake::Client.new(url: url)
          io.write(handshake.to_s)
          until handshake.finished?
            handshake << io.readpartial(1024)
          end
          raise Error, "WebSocket handshake failed" unless handshake.valid?
        end

        def write_frame(io, data, type)
          frame = WebSocket::Frame::Outgoing::Client.new(version: 13, data: data, type: type)
          io.write(frame.to_s)
        end
    end
  end
end
