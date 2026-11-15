# Adds or removes an emoji reaction on a Slack message associated with a Quest.
#
# Reaction failures must NOT fail a QuestExecution. Transient API errors are
# retried a bounded number of times and then logged and discarded.
class SlackReactionJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError
  retry_on Omochi::Slack::RateLimitedError, wait: 5.seconds, attempts: 3 do |_job, error|
    Rails.error.report(error)
  end
  retry_on Omochi::Slack::ApiError, wait: 2.seconds, attempts: 3 do |_job, error|
    Rails.error.report(error)
  end

  def perform(external_resource, message_ts, action = "add", name = "eyes")
    return unless external_resource.platform == "slack" && external_resource.resource_type == "thread"

    channel = external_resource.scope_key.to_s.split("/", 2).last
    return if channel.blank? || message_ts.blank?

    client = Omochi::Slack.build_web_client
    if action.to_s == "remove"
      client.remove_reaction(channel: channel, timestamp: message_ts, name: name)
    else
      client.add_reaction(channel: channel, timestamp: message_ts, name: name)
    end
  end
end
