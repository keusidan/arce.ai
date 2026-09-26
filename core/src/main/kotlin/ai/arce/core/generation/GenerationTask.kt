package ai.arce.core.generation

/** States of one generation, per spec §15. */
enum class TaskState {
    WAITING, SEARCH, THINKING, USER_WAIT, GENERATION, COMPLETED, ERROR, CANCELLED;

    val isTerminal: Boolean get() = this == COMPLETED || this == ERROR || this == CANCELLED
}

/** Why the native side stopped producing tokens. */
enum class FinishReason {
    /** The model emitted an end-of-generation token. */
    EOG,
    /** The token budget ran out; output may be cut off mid-block. */
    LENGTH,
    CANCELLED,
    ERROR,
}

/** What to do after a generation ends, per spec §26/§44. */
sealed interface NextStep {
    data object Done : NextStep
    /** Output was cut off inside a structured block: run the same generation again. */
    data class Regenerate(val attempt: Int) : NextStep
    data class Fail(val reason: String) : NextStep
}

class RetryPolicy(private val maxAttempts: Int) {
    init {
        require(maxAttempts >= 0)
    }

    /**
     * Only a cut-off structured block is regenerated. GBNF already guarantees the JSON syntax,
     * so there is nothing to "repair"; a semantic error is surfaced instead of looping.
     */
    fun decide(
        reason: FinishReason,
        endedInsideToolCall: Boolean,
        semanticError: String?,
        attemptsSoFar: Int,
    ): NextStep = when {
        reason == FinishReason.CANCELLED -> NextStep.Done
        reason == FinishReason.ERROR -> NextStep.Fail("inference error")
        reason == FinishReason.LENGTH && endedInsideToolCall ->
            if (attemptsSoFar < maxAttempts) NextStep.Regenerate(attemptsSoFar + 1)
            else NextStep.Fail("tool call cut off after $attemptsSoFar retries")
        semanticError != null -> NextStep.Fail(semanticError)
        else -> NextStep.Done
    }
}

class GenerationTask {
    var state: TaskState = TaskState.WAITING
        private set

    fun moveTo(next: TaskState) {
        if (next == state) return
        check(!state.isTerminal || next == TaskState.WAITING) { "task already ended in $state" }
        check(next in allowed.getValue(state)) { "illegal transition $state -> $next" }
        state = next
    }

    private companion object {
        val allowed: Map<TaskState, Set<TaskState>> = mapOf(
            TaskState.WAITING to setOf(
                TaskState.SEARCH, TaskState.THINKING, TaskState.GENERATION, TaskState.USER_WAIT,
                TaskState.COMPLETED, TaskState.ERROR, TaskState.CANCELLED,
            ),
            TaskState.SEARCH to setOf(TaskState.THINKING, TaskState.GENERATION, TaskState.ERROR, TaskState.CANCELLED),
            TaskState.THINKING to setOf(TaskState.GENERATION, TaskState.USER_WAIT, TaskState.COMPLETED, TaskState.ERROR, TaskState.CANCELLED),
            TaskState.GENERATION to setOf(TaskState.THINKING, TaskState.USER_WAIT, TaskState.COMPLETED, TaskState.ERROR, TaskState.CANCELLED),
            TaskState.USER_WAIT to setOf(TaskState.GENERATION, TaskState.THINKING, TaskState.CANCELLED),
            TaskState.COMPLETED to setOf(TaskState.WAITING),
            TaskState.ERROR to setOf(TaskState.WAITING),
            TaskState.CANCELLED to setOf(TaskState.WAITING),
        )
    }
}
