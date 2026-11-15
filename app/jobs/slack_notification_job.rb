# Posts a message back to a Slack thread associated with a Quest.
#
# Notification failures must NOT mark a QuestExecution as failed
# (docs/integrations/slack.md §4). Transient API errors are retried a bounded
# number of times and then logged and discarded.
class SlackNotificationJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError
  retry_on Omochi::Slack::RateLimitedError, wait: 5.seconds, attempts: 3 do |_job, error|
    Rails.error.report(error)
  end
  retry_on Omochi::Slack::ApiError, wait: 2.seconds, attempts: 3 do |_job, error|
    Rails.error.report(error)
  end

  def perform(external_resource, text, remove_reaction_ts: nil)
    return unless external_resource.platform == "slack" && external_resource.resource_type == "thread"

    channel = external_resource.scope_key.to_s.split("/", 2).last
    return if channel.blank?

    client = Omochi::Slack.build_web_client
    client.post_message(
      channel: channel,
      thread_ts: external_resource.external_id,
      text: text
    )

    if remove_reaction_ts.present?
      begin
        client.remove_reaction(channel: channel, timestamp: remove_reaction_ts, name: "eyes")
      rescue Omochi::Slack::Error => e
        Rails.error.report(e)
      end
    end
  end
end
