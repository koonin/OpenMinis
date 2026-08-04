package com.openminis.app.tools

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class DelegatedWorkerBrowserPolicyTest {
    @Test
    fun `worker navigation allows only absolute http and https URLs`() {
        assertTrue(DelegatedWorkerBrowserPolicy.isAllowedNavigateUrl("https://example.com/a?q=1"))
        assertTrue(DelegatedWorkerBrowserPolicy.isAllowedNavigateUrl("http://example.com"))

        listOf(
            "minis://memory/GLOBAL.md",
            "file:///var/minis/memory/GLOBAL.md",
            "data:text/plain,secret",
            "javascript:alert(1)",
            "about:blank",
            "//example.com/path",
            "https:example.com",
            "",
        ).forEach { url ->
            assertFalse(url, DelegatedWorkerBrowserPolicy.isAllowedNavigateUrl(url))
        }
    }
}
