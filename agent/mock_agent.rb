#!/usr/bin/env ruby
# frozen_string_literal: true

# Mock Agent executed inside an isolated Quest Agent Container.
#
# It has NO access to Slack / GitHub tokens, database credentials, or the Docker
# socket. It reads the instruction payload from `/workspace/.omochi_instruction.json`
# (written by the worker before starting the container), updates a workspace
# file so workspace persistence across Executions can be verified, and emits
# structured JSON Lines events on stdout.
require "json"
require "time"

$stdout.sync = true
$stderr.sync = true

WORKSPACE_DIR = ENV.fetch("OMOCHI_WORKSPACE", "/workspace")
INSTRUCTION_FILE = File.join(WORKSPACE_DIR, ".omochi_instruction.json")
HISTORY_FILE = File.join(WORKSPACE_DIR, "quest_log.md")

def emit(type, **fields)
  payload = { type: type, timestamp: Time.now.utc.iso8601 }.merge(fields)
  $stdout.puts(JSON.generate(payload))
end

begin
  unless File.exist?(INSTRUCTION_FILE)
    emit("failed", error: "Instruction payload file not found: #{INSTRUCTION_FILE}")
    exit 1
  end

  instruction = JSON.parse(File.read(INSTRUCTION_FILE))
  quest_id = instruction.fetch("quest_public_id")
  sequence = instruction.fetch("instruction_sequence")
  body = instruction.fetch("body").to_s

  emit("started", message: "Mock agent starting for #{quest_id} (instruction ##{sequence})")

  emit("progress", message: "Inspecting workspace and instruction", data: { step: 1, total: 2 })
  emit("log", stream: "stdout", message: "Received instruction ##{sequence} (#{body.bytesize} bytes)")

  # Support deterministic failure simulation in tests when requested explicitly.
  if body.include?("[mock:fail]")
    emit("failed", error: "Mock agent simulated failure as requested")
    exit 2
  end

  if body =~ /\[mock:sleep:(\d+(?:\.\d+)?)\]/
    sleep_seconds = Regexp.last_match(1).to_f.clamp(0.0, 300.0)
    emit("log", stream: "stdout", message: "Sleeping for #{sleep_seconds}s")
    sleep(sleep_seconds)
  end

  emit("progress", message: "Updating workspace log", data: { step: 2, total: 2 })
  File.open(HISTORY_FILE, "a") do |f|
    f.puts("## Instruction ##{sequence} (#{Time.now.utc.iso8601})\n\n#{body}\n")
  end

  first_line = body.lines.first.to_s.strip
  summary = "Mock Agent completed instruction ##{sequence}: #{first_line[0, 120]}"
  emit("completed", summary: summary, data: { workspace_file: File.basename(HISTORY_FILE) })
  exit 0
rescue StandardError => e
  emit("failed", error: "#{e.class}: #{e.message}")
  exit 1
end
