package ai.arce.core.generation

import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.assertThrows

class GenerationTaskTest {
    private val policy = RetryPolicy(maxAttempts = 2)

    @Test
    fun `regenerates only a cut-off tool call, up to the limit`() {
        assertEquals(NextStep.Regenerate(1), policy.decide(FinishReason.LENGTH, true, null, 0))
        assertEquals(NextStep.Regenerate(2), policy.decide(FinishReason.LENGTH, true, null, 1))
        assertEquals(NextStep.Fail("tool call cut off after 2 retries"), policy.decide(FinishReason.LENGTH, true, null, 2))
    }

    @Test
    fun `a long plain answer that hit the limit is kept, not regenerated`() {
        assertEquals(NextStep.Done, policy.decide(FinishReason.LENGTH, false, null, 0))
    }

    @Test
    fun `semantic errors are reported instead of retried`() {
        assertEquals(NextStep.Fail("options are not distinct"), policy.decide(FinishReason.EOG, false, "options are not distinct", 0))
    }

    @Test
    fun `follows the question flow and rejects skipping states`() {
        val task = GenerationTask()
        task.moveTo(TaskState.THINKING)
        task.moveTo(TaskState.USER_WAIT)
        task.moveTo(TaskState.GENERATION)
        task.moveTo(TaskState.COMPLETED)
        assertThrows<IllegalStateException> { task.moveTo(TaskState.GENERATION) }
        task.moveTo(TaskState.WAITING)
        task.moveTo(TaskState.USER_WAIT)
        // a question must be answered (-> GENERATION) or cancelled, never silently completed
        assertThrows<IllegalStateException> { task.moveTo(TaskState.COMPLETED) }
    }
}
