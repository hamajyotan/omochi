ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Creates a Quest with one queued instruction through the public domain API.
    def start_quest(title: "Test quest", body: "Do something", **options)
      Quest.start!(title:, body:, source_platform: "dashboard", **options).quest
    end
  end
end
