package com.openminis.app.tools

import android.content.Context
import java.io.File
import java.net.URLDecoder

/**
 * Runtime path boundary for delegated read-only workers.
 *
 * The policy deliberately returns the canonical [File] that was checked. Tool
 * implementations must read that exact instance instead of resolving the
 * original Linux path a second time (which could reintroduce a global-mount or
 * cross-session fallback).
 */
internal object DelegatedWorkerReadPathPolicy {

    private val sessionScopes = setOf("workspace", "attachments", "offloads", "browser")
    private val forbiddenEncodedPathToken = Regex("%(?:2e|2f|5c|25)", RegexOption.IGNORE_CASE)

    internal enum class RootKind { SESSION, SHARED }

    internal data class ParsedPath(
        val linuxPath: String,
        val rootKind: RootKind,
        val sessionScope: String?,
        val relativePath: String,
    )

    internal data class ResolvedPath(
        val linuxPath: String,
        val file: File,
    )

    /** Pure lexical gate, exposed internally for local JVM tests. */
    internal fun parse(rawPath: String): ParsedPath? {
        val trimmed = rawPath.trim()
        if (trimmed.isEmpty() || trimmed.any { it == '\u0000' || it == '\r' || it == '\n' }) return null
        // Reject encoded dot/separator tokens and encoded '%' up front. The
        // latter closes double-encoding such as %252e%252e%252f.
        if (forbiddenEncodedPathToken.containsMatchIn(trimmed)) return null

        val linuxPath = if (trimmed.startsWith("minis://", ignoreCase = true)) {
            val encoded = trimmed.substring("minis://".length)
            val decoded = runCatching { URLDecoder.decode(encoded, Charsets.UTF_8.name()) }.getOrNull()
                ?: return null
            "/var/minis/$decoded"
        } else {
            trimmed
        }

        if (!linuxPath.startsWith("/var/minis/")) return null
        if ('\\' in linuxPath || linuxPath.any { it == '\u0000' || it == '\r' || it == '\n' }) return null

        val rest = linuxPath.removePrefix("/var/minis/")
        val scope = rest.substringBefore('/')
        if (scope.isEmpty()) return null
        val relative = rest.substringAfter('/', missingDelimiterValue = "")
        val segments = if (relative.isEmpty()) emptyList() else relative.split('/')
        // Empty interior/trailing segments are rejected along with explicit dot
        // traversal so lexical normalization never changes the requested path.
        if (segments.any { it.isEmpty() || it == "." || it == ".." }) return null

        return when {
            scope in sessionScopes -> ParsedPath(
                linuxPath = linuxPath,
                rootKind = RootKind.SESSION,
                sessionScope = scope,
                relativePath = relative,
            )
            scope == "shared" -> ParsedPath(
                linuxPath = linuxPath,
                rootKind = RootKind.SHARED,
                sessionScope = null,
                relativePath = relative,
            )
            else -> null
        }
    }

    fun resolve(
        rawPath: String,
        sessionId: String,
        context: Context,
    ): ResolvedPath? {
        val parsed = parse(rawPath) ?: return null
        return resolveCanonical(
            parsed = parsed,
            filesRoot = context.filesDir,
            sessionId = sessionId,
        )
    }

    /**
     * Canonical containment gate kept independent from Android [Context] so
     * traversal and symlink behavior can be covered by local JVM tests.
     */
    internal fun resolveCanonical(
        parsed: ParsedPath,
        filesRoot: File,
        sessionId: String,
    ): ResolvedPath? {
        return runCatching {
            if (sessionId.isBlank() || '/' in sessionId || '\\' in sessionId || sessionId in setOf(".", "..")) {
                return@runCatching null
            }

            val filesCanonical = filesRoot.canonicalFile
            val sessionsCanonical = File(filesCanonical, "minis-sessions").canonicalFile
            val globalCanonical = File(filesCanonical, "minis-global").canonicalFile
            if (!containsCanonical(filesCanonical, sessionsCanonical) ||
                !containsCanonical(filesCanonical, globalCanonical)
            ) {
                return@runCatching null
            }

            val sessionCanonical = File(sessionsCanonical, sessionId).canonicalFile
            if (!containsCanonical(sessionsCanonical, sessionCanonical)) return@runCatching null

            val sharedCanonical = File(globalCanonical, "shared").canonicalFile
            if (!containsCanonical(globalCanonical, sharedCanonical)) return@runCatching null

            val containmentRoot: File
            val allowedBase: File
            when (parsed.rootKind) {
                RootKind.SESSION -> {
                    containmentRoot = sessionCanonical
                    allowedBase = File(sessionCanonical, parsed.sessionScope!!).canonicalFile
                }
                RootKind.SHARED -> {
                    containmentRoot = globalCanonical
                    allowedBase = sharedCanonical
                }
            }
            // Reject a symlinked workspace/attachment/shared root that escapes
            // its structural owner before checking the requested leaf.
            if (!containsCanonical(containmentRoot, allowedBase)) return@runCatching null

            val target = if (parsed.relativePath.isEmpty()) {
                allowedBase
            } else {
                File(allowedBase, parsed.relativePath).canonicalFile
            }
            if (!containsCanonical(allowedBase, target)) return@runCatching null
            ResolvedPath(parsed.linuxPath, target)
        }.getOrNull()
    }

    private fun containsCanonical(root: File, candidate: File): Boolean {
        val rootPath = root.path.removeSuffix(File.separator)
        val candidatePath = candidate.path
        return candidatePath == rootPath || candidatePath.startsWith(rootPath + File.separator)
    }
}
