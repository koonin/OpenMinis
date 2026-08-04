package com.openminis.app.service

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Semaphore

/**
 * Limits concurrent agent loop sessions to [MAX_CONCURRENT].
 * Excess sessions are suspended in a FIFO queue until a slot frees up.
 */
object SessionConcurrencyManager {
    const val MAX_CONCURRENT = 5

    private val _runningSessions = MutableStateFlow<Set<String>>(emptySet())
    val runningSessions: StateFlow<Set<String>> = _runningSessions.asStateFlow()

    private val _suspendedSessions = MutableStateFlow<List<String>>(emptyList())
    val suspendedSessions: StateFlow<List<String>> = _suspendedSessions.asStateFlow()

    // Coroutine Semaphore owns the atomic permit count and provides FIFO
    // suspension. The old StateFlow size check/update was not atomic, so three
    // workers starting together could all observe the same free slot and push
    // the process above MAX_CONCURRENT.
    private val slots = Semaphore(MAX_CONCURRENT)
    private val stateLock = Any()
    // Public state is session-oriented, while permits are acquisition-oriented:
    // the same session can briefly overlap two agent-loop entry points. Track
    // lease counts internally so Set de-duplication never loses a permit.
    private val runningLeaseCounts = linkedMapOf<String, Int>()
    private val suspendedLeaseCounts = linkedMapOf<String, Int>()

    suspend fun acquireSlot(sessionId: String) {
        val acquiredImmediately = slots.tryAcquire()
        if (!acquiredImmediately) {
            synchronized(stateLock) {
                suspendedLeaseCounts.increment(sessionId)
                publishSuspendedSessionsLocked()
            }
        }
        try {
            if (!acquiredImmediately) slots.acquire()
            synchronized(stateLock) {
                if (!acquiredImmediately) {
                    suspendedLeaseCounts.decrement(sessionId)
                    publishSuspendedSessionsLocked()
                }
                runningLeaseCounts.increment(sessionId)
                publishRunningSessionsLocked()
            }
        } catch (t: Throwable) {
            if (!acquiredImmediately) synchronized(stateLock) {
                suspendedLeaseCounts.decrement(sessionId)
                publishSuspendedSessionsLocked()
            }
            throw t
        }
    }

    fun releaseSlot(sessionId: String) {
        val didOwnSlot = synchronized(stateLock) {
            val owned = (runningLeaseCounts[sessionId] ?: 0) > 0
            if (owned) {
                runningLeaseCounts.decrement(sessionId)
                publishRunningSessionsLocked()
            }
            owned
        }
        // Ignore duplicate/stale release calls; over-releasing a Semaphore
        // throws and would corrupt the global admission boundary.
        if (didOwnSlot) slots.release()
    }

    fun isSuspended(sessionId: String): Boolean = sessionId in _suspendedSessions.value

    private fun MutableMap<String, Int>.increment(sessionId: String) {
        this[sessionId] = (this[sessionId] ?: 0) + 1
    }

    private fun MutableMap<String, Int>.decrement(sessionId: String) {
        val remaining = (this[sessionId] ?: 0) - 1
        if (remaining > 0) this[sessionId] = remaining else remove(sessionId)
    }

    private fun publishRunningSessionsLocked() {
        _runningSessions.value = runningLeaseCounts.keys.toSet()
    }

    private fun publishSuspendedSessionsLocked() {
        _suspendedSessions.value = suspendedLeaseCounts.keys.toList()
    }
}
