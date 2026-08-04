package com.openminis.app.tools

import java.io.File
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assume.assumeNoException
import org.junit.Test

class DelegatedWorkerReadPathPolicyTest {
    private val tempRoot: File = Files.createTempDirectory("worker-read-policy").toFile()

    @After
    fun cleanUp() {
        tempRoot.deleteRecursively()
    }

    @Test
    fun `lexical policy allows only child session scopes and shared`() {
        listOf("workspace", "attachments", "offloads", "browser", "shared").forEach { scope ->
            assertNotNull(
                scope,
                DelegatedWorkerReadPathPolicy.parse("/var/minis/$scope/folder/file.txt"),
            )
        }
        assertNotNull(DelegatedWorkerReadPathPolicy.parse("minis://shared/report.png"))

        listOf(
            "/var/minis/memory/GLOBAL.md",
            "/var/minis/skills/example/SKILL.md",
            "/var/minis/mcp-servers/servers.json",
            "/var/minis/mounts/external/private.txt",
            "/var/minis/rootfs/etc/passwd",
            "/etc/passwd",
            "minis://memory/GLOBAL.md",
        ).forEach { path ->
            assertNull(path, DelegatedWorkerReadPathPolicy.parse(path))
        }
    }

    @Test
    fun `lexical policy rejects literal encoded and double encoded traversal`() {
        listOf(
            "/var/minis/workspace/../memory/GLOBAL.md",
            "/var/minis/workspace/./file.txt",
            "/var/minis/workspace/%2e%2e/memory/GLOBAL.md",
            "minis://workspace/%2E%2E%2Fmemory/GLOBAL.md",
            "minis://workspace/%252e%252e%252fmemory/GLOBAL.md",
            "/var/minis/workspace/..\\memory\\GLOBAL.md",
        ).forEach { path ->
            assertNull(path, DelegatedWorkerReadPathPolicy.parse(path))
        }
    }

    @Test
    fun `canonical policy returns exact in-scope session and shared files`() {
        val sessions = File(tempRoot, "minis-sessions")
        val global = File(tempRoot, "minis-global")
        val workspaceFile = File(sessions, "child/workspace/report.txt").apply {
            parentFile!!.mkdirs()
            writeText("ok")
        }
        val sharedFile = File(global, "shared/public.txt").apply {
            parentFile!!.mkdirs()
            writeText("ok")
        }

        val sessionResolved = DelegatedWorkerReadPathPolicy.resolveCanonical(
            DelegatedWorkerReadPathPolicy.parse("/var/minis/workspace/report.txt")!!,
            tempRoot,
            "child",
        )
        val sharedResolved = DelegatedWorkerReadPathPolicy.resolveCanonical(
            DelegatedWorkerReadPathPolicy.parse("/var/minis/shared/public.txt")!!,
            tempRoot,
            "child",
        )

        assertEquals(workspaceFile.canonicalFile, sessionResolved?.file)
        assertEquals(sharedFile.canonicalFile, sharedResolved?.file)
    }

    @Test
    fun `canonical policy rejects cross-session and shared symlink escape`() {
        val sessions = File(tempRoot, "minis-sessions")
        val global = File(tempRoot, "minis-global")
        val childWorkspace = File(sessions, "child/workspace").apply { mkdirs() }
        val otherWorkspace = File(sessions, "other/workspace").apply { mkdirs() }
        File(otherWorkspace, "secret.txt").writeText("secret")
        val outside = File(tempRoot, "outside").apply { mkdirs() }
        File(outside, "private.txt").writeText("private")
        val shared = File(global, "shared").apply { mkdirs() }

        try {
            Files.createSymbolicLink(File(childWorkspace, "cross").toPath(), otherWorkspace.toPath())
            Files.createSymbolicLink(File(shared, "escape").toPath(), outside.toPath())
        } catch (e: Exception) {
            assumeNoException(e)
        }

        assertNull(
            DelegatedWorkerReadPathPolicy.resolveCanonical(
                DelegatedWorkerReadPathPolicy.parse("/var/minis/workspace/cross/secret.txt")!!,
                tempRoot,
                "child",
            ),
        )
        assertNull(
            DelegatedWorkerReadPathPolicy.resolveCanonical(
                DelegatedWorkerReadPathPolicy.parse("/var/minis/shared/escape/private.txt")!!,
                tempRoot,
                "child",
            ),
        )
    }
}
