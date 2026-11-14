# Phase 1 placeholder runner.
#
# It does NOT run any agent. It only walks the Execution through its lifecycle so
# that the instruction queue can be exercised without Docker. It will be replaced
# by the Docker based Mock Agent runner in Phase 2 (docs/roadmap.md).
class QuestExecution::PlaceholderRunner
  SUMMARY = "No agent was run (Phase 1 placeholder runner).".freeze

  def run(execution)
    execution.mark_preparing!
    execution.mark_running!
    execution.succeed!(result_summary: SUMMARY)
  end
end
