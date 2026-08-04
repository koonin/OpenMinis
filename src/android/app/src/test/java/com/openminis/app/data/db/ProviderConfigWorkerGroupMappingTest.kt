package com.openminis.app.data.db

import com.openminis.app.data.model.ProviderConfig
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Test

class ProviderConfigWorkerGroupMappingTest {

    private val json = Json { ignoreUnknownKeys = true }

    @Test
    fun `worker group id round trips through provider meta snapshot`() {
        val snapshot = ProviderConfig(workerGroupId = "workers-fast")
            .toSnapshot(jsonForBlobs = json)

        assertEquals(
            "workers-fast",
            snapshot.meta.single { it.key == ProviderConfigMetaKeys.WORKER_GROUP_ID }.value,
        )
        assertEquals("workers-fast", snapshot.toProviderConfig(json).workerGroupId)
    }
}
