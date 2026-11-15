ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    setup do
      @fake_docker_client = Omochi::Docker::FakeClient.new
      QuestExecution::DockerRunner.docker_client_factory = -> { @fake_docker_client }

      @fake_slack_client = Omochi::Slack::FakeWebClient.new
      Omochi::Slack.web_client_factory = -> { @fake_slack_client }

      @fake_github_client = Omochi::GitHub::FakeAppClient.new
      Omochi::GitHub.app_client_factory = -> { @fake_github_client }
    end

    # Creates a Quest with one queued instruction through the public domain API.
    def start_quest(title: "Test quest", body: "Do something", **options)
      Quest.start!(title:, body:, source_platform: "dashboard", **options).quest
    end
  end
end
