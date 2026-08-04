package com.openminis.app.tools

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AgentToolsWorkerModeTest {

    @Test
    fun `planner exposes delegation only when explicitly enabled`() {
        val disabled = AgentTools.makeAgentTools(delegationEnabled = false).map { it.name }
        val enabled = AgentTools.makeAgentTools(delegationEnabled = true).map { it.name }

        assertFalse(AgentTools.DELEGATE_TASK_NAME in disabled)
        assertTrue(AgentTools.DELEGATE_TASK_NAME in enabled)
    }

    @Test
    fun `delegated worker schema is read only and cannot recurse`() {
        val tools = AgentTools.makeAgentTools(
            readOnlyWorker = true,
            delegationEnabled = true,
            memoryEnabled = true,
        )
        val names = tools.map { it.name }.toSet()

        assertEquals(setOf("file_read", "read_image", "browser_use"), names)
        assertFalse("shell_execute" in names)
        assertFalse("file_write" in names)
        assertFalse("file_edit" in names)
        assertFalse("memory_write" in names)
        assertFalse("memory_get" in names)
        assertFalse(AgentTools.DELEGATE_TASK_NAME in names)
    }

    @Test
    fun `delegated browser action enum matches native read only allowlist`() {
        val browser = AgentTools.makeAgentTools(readOnlyWorker = true)
            .single { it.name == "browser_use" }
        val schemaValues = browser.parameters.getValue("action").enumValues.orEmpty().toSet()

        assertEquals(AgentTools.READ_ONLY_BROWSER_ACTIONS.map { it.value }.toSet(), schemaValues)
        assertFalse("click" in schemaValues)
        assertFalse("type" in schemaValues)
        assertFalse("execute_js" in schemaValues)
        assertFalse("set_cookies" in schemaValues)
        assertFalse("fetch" in schemaValues)
    }
}
