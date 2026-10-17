package dev.omputer.omputer

import android.content.Context
import android.net.ConnectivityManager
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Handler
import android.os.Looper
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.NetworkInterface
import java.net.SocketTimeoutException
import java.util.concurrent.Executors
import org.json.JSONObject
import java.net.URI
import java.util.ArrayDeque

internal data class NearbyComputer(val id: String, val name: String, val url: String, val fingerprint: String) {
    fun asMap() = mapOf("id" to id, "name" to name, "url" to url, "fingerprint" to fingerprint)
}

/** Advertisements locate candidates only. LocalConnection separately pins TLS and requires PC approval. */
internal class NearbyComputers(private val context: Context, private val changed: (Map<String, Any?>) -> Unit,
    private val found: (NearbyComputer) -> Unit) {
    private val main = Handler(Looper.getMainLooper())
    private val nsd = context.getSystemService(NsdManager::class.java)
    private val computers = linkedMapOf<String, NearbyComputer>()
    private val services = mutableMapOf<String, String>()
    private val queue = ArrayDeque<NsdServiceInfo>()
    private var listener: NsdManager.DiscoveryListener? = null
    private var multicast: WifiManager.MulticastLock? = null
    private var resolving = false
    @Volatile private var revision = 0
    @Volatile private var enabled = false
    private val udpWorker = Executors.newSingleThreadExecutor()
    @Volatile private var udpSocket: DatagramSocket? = null
    private val seen = mutableMapOf<String, Long>()
    private var error: String? = null
    @Synchronized fun state(): Map<String, Any?> = mapOf("computers" to computers.values.map { it.asMap() },
        "scanning" to (listener != null), "error" to error)
    @Synchronized fun computer(id: String): NearbyComputer? = computers[id]
    fun setEnabled(value: Boolean): Map<String, Any?> {
        main.post { enabled = value; if (value) start() else stop() }
        return state()
    }
    fun networkChanged() { main.post { if (enabled) { stop(); start() } } }
    private fun publish() = changed(state())
    private fun start() {
        if (listener != null) { publish(); return }
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        if (connectivity.activeNetwork == null) { error = "Ağ bağlantısı yok. Bilgisayarınla aynı yerel ağa bağlan; arama otomatik sürer."; publish(); return }
        error = null
        val ticket = ++revision
        try {
            multicast = context.getSystemService(WifiManager::class.java).createMulticastLock("Omputer:discovery").apply { setReferenceCounted(false); acquire() }
            val callback = object : NsdManager.DiscoveryListener {
                override fun onDiscoveryStarted(type: String) { publish() }
                override fun onServiceFound(service: NsdServiceInfo) {
                    main.post {
                        if (ticket == revision && service.serviceType.trimEnd('.') in setOf("_omputer._tcp", "_omputer._tcp.local") && queue.size < 64) {
                            services[service.serviceName]?.let { seen[it] = System.currentTimeMillis() }
                            if (queue.none { it.serviceName == service.serviceName }) queue.add(service)
                            resolve(ticket)
                        }
                    }
                }
                override fun onServiceLost(service: NsdServiceInfo) { main.post {
                    if (ticket != revision) return@post
                    synchronized(this@NearbyComputers) { services.remove(service.serviceName)?.let { computers.remove(it) } }; publish()
                } }
                override fun onDiscoveryStopped(type: String) {}
                override fun onStartDiscoveryFailed(type: String, code: Int) { main.post { if (ticket == revision) fail("Yakındaki bilgisayarlar aranamadı ($code). Wi-Fi ve yerel ağ izinlerini kontrol et.") } }
                override fun onStopDiscoveryFailed(type: String, code: Int) {}
            }
            listener = callback
            nsd.discoverServices("_omputer._tcp.", NsdManager.PROTOCOL_DNS_SD, callback)
            startUdp(ticket)
            publish()
        } catch (failure: Exception) { fail("Yerel ağ keşfi kullanılamıyor: ${failure.message}. Android ağ izinlerini kontrol et.") }
    }
    @Suppress("DEPRECATION")
    private fun resolve(ticket: Int) {
        if (resolving || queue.isEmpty() || ticket != revision) return
        resolving = true
        val service = queue.removeFirst()
        try { nsd.resolveService(service, object : NsdManager.ResolveListener {
            override fun onResolveFailed(info: NsdServiceInfo, code: Int) { main.post { if (ticket == revision) { resolving = false; resolve(ticket) } } }
            override fun onServiceResolved(info: NsdServiceInfo) { main.post {
                if (ticket != revision) return@post
                resolving = false
                val id = info.attributes["id"]?.toString(Charsets.UTF_8).orEmpty()
                val fingerprint = info.attributes["fp"]?.toString(Charsets.UTF_8).orEmpty().lowercase()
                val version = info.attributes["v"]?.toString(Charsets.UTF_8)
                val host = info.host?.hostAddress
                if (id.isNotBlank() && id.length <= 128 && fingerprint.matches(Regex("[0-9a-f]{64}")) && version == "1" && host != null && info.port in 1..65535) {
                    val url = URI("https", null, host, info.port, null, null, null).toASCIIString()
                    val computer = NearbyComputer(id, info.serviceName.take(100), url, fingerprint)
                    synchronized(this@NearbyComputers) { if (computers.size < 64 || computers.containsKey(id)) { computers[id] = computer; services[info.serviceName] = id; seen[id] = System.currentTimeMillis() } }
                    publish(); found(computer)
                }
                resolve(ticket)
            } }
        }) } catch (failure: Exception) {
            resolving = false
            error = "Bilgisayarın ağ bilgisi çözülemedi: ${failure.message}. Arama yeniden denenecek."
            publish()
            main.postDelayed({ if (ticket == revision) resolve(ticket) }, 1000)
        }
    }
    private fun fail(message: String) {
        stop(); error = message; publish()
        val ticket = revision
        main.postDelayed({ if (enabled && ticket == revision) start() }, 5000)
    }
    private fun startUdp(ticket: Int) {
        udpWorker.execute {
            try {
                DatagramSocket().use { socket ->
                    udpSocket = socket; socket.broadcast = true; socket.soTimeout = 1000
                    val bytes = "OMPUTER_DISCOVER_V1".toByteArray(Charsets.US_ASCII)
                    var sent = 0L
                    var received = 0
                    while (ticket == revision && enabled && !socket.isClosed) {
                        if (System.currentTimeMillis() - sent >= 5000) {
                            sent = System.currentTimeMillis()
                            received = 0
                            val targets = linkedSetOf(InetAddress.getByName("255.255.255.255"))
                            NetworkInterface.getNetworkInterfaces()?.toList()?.filter { it.isUp && !it.isLoopback }?.forEach { network -> network.interfaceAddresses.mapNotNullTo(targets) { it.broadcast } }
                            targets.take(8).forEach { address -> try { socket.send(DatagramPacket(bytes, bytes.size, address, 47878)) } catch (_: Exception) {} }
                            main.post { if (ticket == revision) { synchronized(this@NearbyComputers) { seen.filter { (id, time) -> id !in services.values && System.currentTimeMillis() - time > 20_000 }.keys.toList().forEach { computers.remove(it); seen.remove(it) } }; publish() } }
                        }
                        val packet = DatagramPacket(ByteArray(2048), 2048)
                        try { socket.receive(packet) } catch (_: SocketTimeoutException) { continue }
                        if (++received > 64) continue
                        val address = packet.address
                        val local = address.isSiteLocalAddress || address.isLoopbackAddress || (address.address.size == 16 && (address.address[0].toInt() and 0xfe) == 0xfc)
                        if (!local) continue
                        val value = try { JSONObject(String(packet.data, 0, packet.length, Charsets.UTF_8)) } catch (_: Exception) { continue }
                        val id = value.optString("id"); val fp = value.optString("fingerprint").lowercase(); val port = value.optInt("port")
                        if (value.optInt("v") != 1 || id.isBlank() || id.length > 128 || !fp.matches(Regex("[0-9a-f]{64}")) || port !in 1..65535) continue
                        val computer = NearbyComputer(id, value.optString("name", "Omputer").take(100), URI("https", null, address.hostAddress, port, null, null, null).toASCIIString(), fp)
                        main.post { if (ticket == revision) { synchronized(this@NearbyComputers) { if (computers.size < 64 || computers.containsKey(id)) { computers[id] = computer; seen[id] = System.currentTimeMillis() } }; publish(); found(computer) } }
                    }
                }
            } catch (_: Exception) { /* DNS-SD remains the primary discovery transport. */ }
        }
    }
    private fun stop() {
        revision++; resolving = false; queue.clear()
        listener?.let { try { nsd.stopServiceDiscovery(it) } catch (_: Exception) {} }; listener = null
        multicast?.let { if (it.isHeld) it.release() }; multicast = null
        synchronized(this) { computers.clear(); services.clear(); seen.clear() }; publish()
        udpSocket?.close(); udpSocket = null
    }
}
