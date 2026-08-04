package com.openminis.app.service

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionConcurrencyManagerTest {

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun `concurrent admission never exceeds global limit`() = runTest {
        val releaseGate = CompletableDeferred<Unit>()
        val jobs = (0 until 8).map { index ->
            async {
                val id = "concurrency-test-$index"
                SessionConcurrencyManager.acquireSlot(id)
                try {
                    releaseGate.await()
                } finally {
                    SessionConcurrencyManager.releaseSlot(id)
                }
            }
        }

        runCurrent()
        assertEquals(
            SessionConcurrencyManager.MAX_CONCURRENT,
            SessionConcurrencyManager.runningSessions.value.size,
        )
        assertEquals(3, SessionConcurrencyManager.suspendedSessions.value.size)
        assertTrue(
            SessionConcurrencyManager.runningSessions.value.size <=
                SessionConcurrencyManager.MAX_CONCURRENT,
        )

        releaseGate.complete(Unit)
        jobs.awaitAll()
        assertTrue(SessionConcurrencyManager.runningSessions.value.isEmpty())
        assertTrue(SessionConcurrencyManager.suspendedSessions.value.isEmpty())
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun `overlapping same-session leases release independently and restore capacity`() = runTest {
        SessionConcurrencyManager.acquireSlot("same")
        SessionConcurrencyManager.acquireSlot("same")
        SessionConcurrencyManager.acquireSlot("holder-1")
        SessionConcurrencyManager.acquireSlot("holder-2")
        SessionConcurrencyManager.acquireSlot("holder-3")

        val waiter = async { SessionConcurrencyManager.acquireSlot("waiter") }
        runCurrent()
        assertFalse(waiter.isCompleted)
        assertTrue(SessionConcurrencyManager.isSuspended("waiter"))

        SessionConcurrencyManager.releaseSlot("same")
        runCurrent()
        assertTrue(waiter.isCompleted)
        // One independent lease for the same session remains active.
        assertTrue("same" in SessionConcurrencyManager.runningSessions.value)

        SessionConcurrencyManager.releaseSlot("same")
        SessionConcurrencyManager.releaseSlot("holder-1")
        SessionConcurrencyManager.releaseSlot("holder-2")
        SessionConcurrencyManager.releaseSlot("holder-3")
        SessionConcurrencyManager.releaseSlot("waiter")

        val recovered = (0 until SessionConcurrencyManager.MAX_CONCURRENT).map { index ->
            async { SessionConcurrencyManager.acquireSlot("recovered-$index") }
        }
        runCurrent()
        assertTrue(recovered.all { it.isCompleted })
        recovered.indices.forEach { index ->
            SessionConcurrencyManager.releaseSlot("recovered-$index")
        }
        assertTrue(SessionConcurrencyManager.runningSessions.value.isEmpty())
        assertTrue(SessionConcurrencyManager.suspendedSessions.value.isEmpty())
    }
}
