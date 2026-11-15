# Posts a Pull Request Review or Issue Comment back to GitHub.
#
# Notification failures must NOT mark a QuestExecution as failed.
# Transient API errors are retried a bounded number of times and then logged.
class GitHubNotificationJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError
  retry_on Omochi::GitHub::RateLimitedError, wait: 10.seconds, attempts: 3 do |_job, error|
    Rails.error.report(error)
  end
  retry_on Omochi::GitHub::ApiError, wait: 2.seconds, attempts: 3 do |_job, error|
    Rails.error.report(error)
  end

  def perform(external_resource, text, event_type: "COMMENT")
    return unless external_resource.platform == "github"

    repository = external_resource.scope_key # e.g. "hamajyotan/omochi"
    number = external_resource.external_id # e.g. "42"
    client = Omochi::GitHub.build_app_client

    # Installation ID can be stored in external_resource or looked up; for now
    # pass 0 or configured installation if single-tenant.
    installation_id = ENV.fetch("GITHUB_APP_INSTALLATION_ID", 1).to_i

    if external_resource.resource_type == "pull_request"
      client.create_pull_request_review(
        installation_id: installation_id,
        repository: repository,
        pull_number: number,
        body: text,
        event: event_type
      )
    else
      client.create_issue_comment(
        installation_id: installation_id,
        repository: repository,
        issue_number: number,
        body: text
      )
    end
  end
end
