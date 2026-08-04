package com.openminis.app.tools

import java.net.URI

/** Runtime URL boundary for delegated-worker browser navigation. */
internal object DelegatedWorkerBrowserPolicy {
    internal fun isAllowedNavigateUrl(rawUrl: String?): Boolean {
        val url = rawUrl?.trim()?.takeIf { it.isNotEmpty() } ?: return false
        val uri = runCatching { URI(url) }.getOrNull() ?: return false
        val scheme = uri.scheme?.lowercase() ?: return false
        return scheme in setOf("http", "https") && !uri.rawAuthority.isNullOrBlank()
    }
}
