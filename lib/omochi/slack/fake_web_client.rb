# In-memory test double for `Omochi::Slack::WebClient`.
module Omochi
  module Slack
    class FakeWebClient
      attr_reader :posted_messages, :reactions_added, :reactions_removed, :socket_open_count, :downloaded_urls
      attr_accessor :wss_url, :on_post_message, :files

      def initialize(wss_url: "wss://fake.slack.example/link")
        @wss_url = wss_url
        @posted_messages = []
        @reactions_added = []
        @reactions_removed = []
        @downloaded_urls = []
        @files = {}
        @socket_open_count = 0
      end

      def open_socket_connection
        @socket_open_count += 1
        @wss_url
      end

      def post_message(channel:, thread_ts:, text:)
        return @on_post_message.call(channel: channel, thread_ts: thread_ts, text: text) if @on_post_message

        msg = { channel: channel.to_s, thread_ts: thread_ts.to_s, text: text.to_s }
        @posted_messages << msg
        { "ok" => true, "ts" => "1700000000.000200", "message" => msg }
      end

      def add_reaction(channel:, timestamp:, name:)
        reaction = { channel: channel.to_s, timestamp: timestamp.to_s, name: name.to_s }
        @reactions_added << reaction
        { "ok" => true }
      end

      def remove_reaction(channel:, timestamp:, name:)
        reaction = { channel: channel.to_s, timestamp: timestamp.to_s, name: name.to_s }
        @reactions_removed << reaction
        { "ok" => true }
      end

      def download_file(url, max_bytes: 10 * 1024 * 1024)
        @downloaded_urls << url.to_s
        @files[url.to_s] || "fake-image-bytes"
      end
    end
  end
end
