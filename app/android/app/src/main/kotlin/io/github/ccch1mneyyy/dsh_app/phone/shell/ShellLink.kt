package io.github.ccch1mneyyy.dsh_app.phone.shell

import android.os.Bundle
import io.github.ccch1mneyyy.dsh_app.phone.background.Bundles
import io.github.muntashirakon.adb.AdbStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import kotlin.concurrent.thread
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

internal data class ShellConnection(val link: ShellLink? = null, val errorCode: String? = null)

/** A timed-out exchange always retires the link; its response can never become a later reply. */
internal class ShellLink(
    val backend: String,
    private val exchange: (Bundle) -> Bundle,
    private val transportAlive: () -> Boolean,
    private val retire: () -> Unit,
) {
    private val closed = AtomicBoolean(false)
    private val serial = Any()
    private val worker = Executors.newSingleThreadExecutor { task ->
        Thread(task, "dsh-shell-rpc").apply { isDaemon = true }
    }
    @Volatile var uid: Int = -1
        private set
    @Volatile private var instance: String? = null

    fun probe(timeoutMs: Long = ShellProtocol.RPC_TIMEOUT_MS): Boolean {
        val response = call(mapOf("op" to "probe"), timeoutMs)
        val actualUid = response["uid"] as? Int ?: return false
        val peer = response["instance"] as? String ?: return false
        if (response["ok"] != true || response["revision"] != ShellProtocol.REVISION ||
            !ShellProtocol.validUid(backend, actualUid) || peer.isBlank()) return false
        uid = actualUid
        instance = peer
        return true
    }

    fun call(values: Map<String, Any?>, timeoutMs: Long = ShellProtocol.RPC_TIMEOUT_MS, beforeSend: () -> Boolean = { true }): Map<String, Any?> = synchronized(serial) {
        if (!alive()) throw IOException("transportLost")
        val body = values + mapOf("revision" to ShellProtocol.REVISION, "instance" to instance)
        val future = worker.submit<Bundle> {
            if (!beforeSend()) shellBundle(ShellProtocol.failure("cancelled")) else exchange(shellBundle(body))
        }
        try {
            future.get(timeoutMs, TimeUnit.MILLISECONDS).shellMap()
        } catch (error: Exception) {
            future.cancel(true)
            close()
            if (error is InterruptedException) Thread.currentThread().interrupt()
            throw IOException("transportLost")
        }
    }

    fun alive(): Boolean = !closed.get() && transportAlive()

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        worker.shutdownNow()
        Thread({ runCatching { retire() } }, "dsh-shell-retire").apply { isDaemon = true; start() }
    }

    companion object {
        fun adb(stream: AdbStream): ShellLink =
            framed("adb", stream.openInputStream(), stream.openOutputStream(), { !stream.isClosed }, { stream.close() })

        fun root(process: Process): ShellLink {
            // The root manager can write diagnostics while authorization is pending.
            thread(name = "dsh-shell-root-stderr", isDaemon = true) {
                runCatching {
                    process.errorStream.use { error ->
                        val buffer = ByteArray(4096)
                        while (error.read(buffer) >= 0) { }
                    }
                }
            }
            return framed("root", process.inputStream, process.outputStream, { process.isAlive }) {
                // EOF makes AndroidShellMain destroy any owned command before exiting.
                try { process.outputStream.close() } finally { process.destroy() }
            }
        }

        private fun framed(
            backend: String,
            input: InputStream,
            output: OutputStream,
            alive: () -> Boolean,
            close: () -> Unit,
        ): ShellLink {
            var synced = false
            return ShellLink(backend, { request ->
                if (!synced) { ShellWire.sync(input); synced = true }
                ShellWire.write(output, Bundles.marshal(request))
                Bundles.unmarshal(ShellWire.read(input) ?: throw IOException("transportLost"))
            }, alive, close)
        }
    }
}
