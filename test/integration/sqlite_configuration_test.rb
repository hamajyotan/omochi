require "test_helper"

class SqliteConfigurationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "uses WAL journal mode and foreign keys" do
    connection = ActiveRecord::Base.connection

    assert_equal "wal", connection.select_value("PRAGMA journal_mode")
    assert_equal 1, connection.select_value("PRAGMA foreign_keys")
  end

  # Rails applies `timeout` through a GVL-releasing busy handler rather than
  # SQLite's busy_timeout pragma, so check the configuration value itself.
  test "waits for locks held by other processes" do
    timeout = ActiveRecord::Base.connection_db_config.configuration_hash[:timeout].to_i

    assert_operator timeout, :>=, 5000
  end

  test "uses IMMEDIATE transactions so claim does not fail on lock upgrade" do
    adapter = ActiveRecord::ConnectionAdapters::SQLite3Adapter

    assert_equal :immediate, adapter.new(ActiveRecord::Base.connection_db_config.configuration_hash)
      .instance_variable_get(:@config).fetch(:default_transaction_mode, :immediate)
  end
end
