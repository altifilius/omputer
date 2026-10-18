package dev.omputer.omputer

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.LinkProperties
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.util.Base64
import okhttp3.Call
import okhttp3.Callback
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.IOException
import java.net.URI
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateFactory
import java.security.cert.X509Certificate
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager

internal class ApiFailure(val code: String, override val message: String) : Exception(message)

internal object LocalConnection {
    private lateinit var context: Context
    private lateinit var vault: LocalVault
    @Volatile private var currentSnapshot = LocalVault.emptySnapshot()
    private fun executor(threads: Int, capacity: Int) = java.util.concurrent.ThreadPoolExecutor(threads, threads, 0L,
        TimeUnit.MILLISECONDS, java.util.concurrent.ArrayBlockingQueue<Runnable>(capacity))
    private val worker = executor(1, 24)
    private val requests = executor(4, 32)
    private val replies = executor(1, 8)
    private val pairing = executor(1, 8)
    private val rediscovery = Executors.newSingleThreadScheduledExecutor()
    private val rediscoveryBusy = AtomicBoolean(false)
    private var rediscoveryCandidate: NearbyComputer? = null
    private var nextRediscoveryAt = 0L
    private val rediscoveryAttempts = linkedMapOf<String, Long>()
    private lateinit var nearby: NearbyComputers
    private var pendingPair: JSONObject? = null
    private var pendingClient: OkHttpClient? = null
    private var pairCall: Call? = null
    @Volatile private var pairRevision = 0
    private val main = Handler(Looper.getMainLooper())
    private val uiEvents = NativeEventBuffer()
    private val uiScheduled = AtomicBoolean(false)
    private val uiDrain = Runnable {
        uiScheduled.set(false)
        uiEvents.drain(generation).forEach { queued ->
            if (queued.type != "connection" && listeners.isEmpty()) return@forEach
            val data = if (queued.data is JSONObject) queued.data.asMap() else queued.data
            val event = mapOf("type" to queued.type, "data" to data)
            listeners.forEach { it(event) }
            if (queued.type == "connection") onConnectionChanged?.invoke()
        }
    }
    private var openingCall: Call? = null
    private var retry: Runnable? = null
    private var networkSignature: String? = null
    private val networkUpdate = Runnable {
        val connectivity = context.getSystemService(ConnectivityManager::class.java)
        val network = connectivity.activeNetwork
        val properties = network?.let { connectivity.getLinkProperties(it) }
        val signature = "$network|${properties?.interfaceName}|${properties?.linkAddresses}|${properties?.routes}"
        synchronized(this) {
            if (signature == networkSignature) return@Runnable
            networkSignature = signature
            nearby.networkChanged()
            if (active && !vault.revoked) reconnect()
        }
    }
    private val listeners = CopyOnWriteArraySet<(Map<String, Any?>) -> Unit>()
    private var socket: WebSocket? = null
    private var client: OkHttpClient? = null
    @Volatile private var generation = 0
    @Volatile private var active = false
    @Volatile private var connected = false
    @Volatile private var connecting = false
    @Volatile private var lastError: String? = null
    @Volatile var activityVisible = false
    private var retrySeconds = 1L
    private var pendingNavigation: Map<String, Any?>? = null
    private val acceptedInteractions = linkedMapOf<String, String>()
    var onConnectionChanged: (() -> Unit)? = null

    @Synchronized fun initialize(application: Context) {
        if (::context.isInitialized) return
        context = application.applicationContext
        vault = LocalVault(context)
        currentSnapshot = vault.snapshot()
        notificationDeviceId = try { vault.credentials()?.optString("deviceId") } catch (_: Exception) { null }
        notificationScopedIdentity = try { vault.credentials()?.let { DurableLocalState.identity(it) } } catch (_: Exception) { null }
        LocalNotifications.initialize(context)
        val scope = notificationScopedIdentity
        if (scope != null) execute({ vault.durable.state(scope).getJSONObject("sections").getJSONObject("notificationPreferences") }) { value, error ->
            if (error == null && scope == notificationScopedIdentity) {
                notificationPreferences = value as JSONObject
                execute({ LocalNotifications.reconcile(context, currentSnapshot); null }) { _, _ -> }
            }
        }
        nearby = NearbyComputers(context, { emit("discovery", it) }, ::rediscovered)
        context.getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = networkChanged()
            override fun onLost(network: Network) = networkChanged()
            override fun onLinkPropertiesChanged(network: Network, properties: LinkProperties) = networkChanged()
        })
    }

    fun addListener(listener: (Map<String, Any?>) -> Unit) {
        listeners.add(listener)
        listener(mapOf("type" to "connection", "data" to connection()))
        listener(mapOf("type" to "snapshot", "data" to snapshot()))
        listener(mapOf("type" to "discovery", "data" to nearby.state()))
        synchronized(this) { pendingNavigation?.let { listener(it); pendingNavigation = null } }
    }
    fun removeListener(listener: (Map<String, Any?>) -> Unit) { listeners.remove(listener) }
    private fun emit(type: String, data: Any?) {
        if (listeners.isEmpty() && type != "connection") return
        val key = if (type == "event" && data is JSONObject) {
            if (data.optString("type") == "message.upsert") {
                val row = data.optJSONObject("data")?.optJSONObject("message") ?: data.optJSONObject("data")
                "message:${data.optString("sessionId")}:${row?.optString("id")}"
            } else "event:${data.optLong("sequence")}"
        } else type
        uiEvents.offer(NativeEventBuffer.Event(type, data, generation, if (type == "event") data.toString().length else 0), key)
        if (uiScheduled.compareAndSet(false, true)) main.post(uiDrain)
    }
    fun navigate(data: Map<String, Any?>) {
        val event = mapOf("type" to "navigate", "data" to data)
        synchronized(this) { if (listeners.isEmpty()) pendingNavigation = event }
        emit("navigate", data)
    }
    fun snapshot(): Map<String, Any?> = currentSnapshot.asMap()
    @Synchronized fun localIdentity(): String {
        if (vault.revoked) throw ApiFailure("device_revoked", "Bu cihazın yetkisi kaldırıldı; yeniden eşleştir.")
        return notificationScopedIdentity ?: throw ApiFailure("not_paired", "Önce PC ile eşleştir.")
    }
    @Synchronized fun withIdentity(identity: String, operation: () -> Any?): Any? {
        if (identity != localIdentity()) throw ApiFailure("connection_changed", "Eşleştirme değişti; önceki bilgisayarın yerel işlemi uygulanmadı.")
        return operation()
    }
    @Synchronized fun localState() = vault.durable.state(localIdentity()).asMap()
    @Synchronized fun localStateSet(section: String, key: String, value: Any?): Map<String, Any?> {
        val state = vault.durable.set(localIdentity(), section, key, JSONObject.wrap(value)).asMap()
        if (section == "notificationPreferences") {
            notificationPreferences = vault.durable.state(localIdentity()).getJSONObject("sections").getJSONObject("notificationPreferences")
            LocalNotifications.cancelAll(context); LocalNotifications.reconcile(context, currentSnapshot)
        }
        return state
    }
    @Synchronized fun draftLoad(key: String) = vault.durable.draft(localIdentity(), key)?.asMap()
    @Synchronized fun draftList() = vault.durable.drafts(localIdentity()).asMap()
    @Synchronized fun draftSave(key: String, value: Map<*, *>) { vault.durable.saveDraft(localIdentity(), key, JSONObject(value)) }
    @Synchronized fun draftDelete(key: String) { vault.durable.deleteDraft(localIdentity(), key) }
    @Synchronized fun operationSave(operation: Map<*, *>) { vault.durable.saveOperation(localIdentity(), JSONObject(operation)) }
    @Synchronized fun operationList(): List<Any?> = jsonValue(vault.durable.operations(localIdentity())) as List<Any?>
    @Synchronized fun operationRemove(id: String) { vault.durable.removeOperation(localIdentity(), id) }
    @Synchronized fun importImages(identity: String, uris: List<android.net.Uri>, shared: Boolean = false): List<Map<String, Any?>> {
        if (identity != localIdentity()) throw ApiFailure("connection_changed", "Eşleştirme değişti; önceki görseller eklenmedi.")
        return vault.attachments.import(identity, uris, shared)
    }
    @Synchronized fun sharedImages() = vault.attachments.shared(localIdentity())
    fun notificationReply(body: Map<String, Any?>, identity: String?, complete: (Any?, Throwable?) -> Unit) {
        submit(replies, complete) {
            val scope = synchronized(this) {
                if (identity != notificationDeviceId) throw ApiFailure("connection_changed", "Eşleştirme değişti; eski cevap gönderilmedi.")
                localIdentity()
            }
            val id = body["id"] as String
            val old = synchronized(this) { vault.durable.operations(scope).let { rows -> (0 until rows.length()).map { rows.getJSONObject(it) }.firstOrNull { it.optString("id") == id } } }
            val record = old ?: JSONObject().put("id", id).put("request", JSONObject(body)).put("action", "interaction.respond")
                .put("sessionId", body["sessionId"]).put("status", "unknown").put("nativeReply", true)
                .put("createdAt", java.time.Instant.now().toString())
            val ticket = synchronized(this) {
                if (scope != localIdentity()) throw ApiFailure("connection_changed", "Eşleştirme değişti.")
                vault.durable.saveOperation(scope, record)
                generation
            }
            try {
                // A repeated Android broadcast reconciles its UUID, never resubmits an uncertain reply.
                val response = if (old != null) request("GET", "/v1/commands/$id", expectedGeneration = ticket) else request("POST", "/v1/commands", body, expectedGeneration = ticket, retainCommandError = true)
                val value = JSONObject(response)
                val envelope = value.optJSONObject("result") ?: value
                record.put("status", value.optString("status").ifBlank { if (DecisionPolicy.finalSuccess(envelope)) "succeeded" else "unknown" })
                    .put("result", envelope).put("updatedAt", java.time.Instant.now().toString())
                synchronized(this) {
                    if (scope != localIdentity()) throw ApiFailure("connection_changed", "Eşleştirme değişti.")
                    vault.durable.saveOperation(scope, record)
                }
                DecisionPolicy.commandError(envelope)?.let { throw ApiFailure(it.first, it.second) }
                response
            } catch (error: Exception) {
                synchronized(this) {
                    if (runCatching { localIdentity() }.getOrNull() == scope) {
                        record.put("lastError", error.message).put("updatedAt", java.time.Instant.now().toString())
                        vault.durable.saveOperation(scope, record)
                    }
                }
                throw error
            }
        }
    }
    @Synchronized private fun reconcileNativeReply(operation: JSONObject) {
        val scope = localIdentity()
        val rows = vault.durable.operations(scope)
        val record = (0 until rows.length()).map { rows.getJSONObject(it) }
            .firstOrNull { it.optString("id") == operation.optString("id") && it.optBoolean("nativeReply") } ?: return
        operation.keys().forEach { record.put(it, operation.opt(it)) }
        vault.durable.saveOperation(scope, record)
        val result = operation.optJSONObject("result") ?: return
        val interaction = record.optJSONObject("request")?.optJSONObject("payload")?.optString("interactionId") ?: return
        if (DecisionPolicy.finalSuccess(result)) {
            acceptedInteractions[interaction] = "resolved"
            val pending = pendingInteraction(interaction)
            if (pending != null) {
                val snapshot = shallowCopy(currentSnapshot)
                replaceRow(snapshot, "interactions", shallowCopy(pending).put("status", "resolved"))
                saveSnapshot(snapshot)
            }
            LocalNotifications.cancelInteraction(context, interaction)
        } else DecisionPolicy.commandError(result)?.let { failure ->
            LocalNotifications.post(context, JSONObject().put("id", "reply-error:${operation.optString("id")}")
                .put("kind", "error").put("sessionId", record.optString("sessionId"))
                .put("title", "Cevap kabul edilmedi").put("body", failure.second))
        }
    }
    private fun reconcileNativeReplies() {
        val scope = localIdentity()
        val (identity, pending) = synchronized(this) {
            val rows = vault.durable.operations(scope)
            notificationDeviceId to (0 until rows.length()).map { rows.getJSONObject(it) }.filter {
                it.optBoolean("nativeReply") && it.optString("status") !in setOf("succeeded", "failed")
            }.take(8).map { it.getString("id") }
        }
        pending.forEach { id -> requestAsync("GET", "/v1/commands/$id", expectedIdentity = identity) { value, error ->
            if (error == null && value is Map<*, *>) submit(replies, { _, _ -> }) {
                withIdentity(scope) { reconcileNativeReply(JSONObject(value)); null }
            }
        } }
    }
    @Synchronized fun removeAttachment(id: String) { vault.attachments.remove(localIdentity(), id) }
    fun notificationEnabled(session: String?, project: String?, kind: String): Boolean {
        val projectId = project ?: currentSnapshot.optJSONArray("sessions")?.let { rows ->
            (0 until rows.length()).mapNotNull { rows.optJSONObject(it) }.firstOrNull { it.optString("id") == session }?.optString("projectId")
        }
        return NotificationPreferences.enabled(notificationPreferences, session, projectId, kind)
    }
    fun preferences(): Map<String, Any?> {
        val info = context.packageManager.getPackageInfo(context.packageName, 0)
        val build = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
        return mapOf("theme" to vault.theme, "appVersion" to info.versionName, "buildNumber" to build.toString(), "protocol" to 1,
            "identity" to runCatching { localIdentity() }.getOrNull(), "lastSyncAt" to vault.lastSyncAt, "cacheFresh" to connected,
            "components" to currentSnapshot.optJSONObject("components")?.asMap())
    }
    fun setTheme(mode: String) {
        require(mode in setOf("system", "dark", "light")) { "Geçersiz görünüm tercihi." }
        vault.theme = mode
    }
    fun isBackground() = vault.background
    fun setBackground(enabled: Boolean) {
        if (enabled && vault.revoked) throw ApiFailure("device_revoked", "Bu cihazın yetkisi kaldırıldı; yeniden eşleştir.")
        vault.background = enabled; publishConnection()
    }
    @Volatile private var backgroundRunning = false
    fun serviceRunning(running: Boolean) { backgroundRunning = running; publishConnection() }
    fun backgroundUnavailable(message: String) { backgroundRunning = false; lastError = "Arka plan bağlantısı başlatılamadı: $message"; publishConnection() }
    fun startBackgroundIfAllowed() {
        if (!vault.background || vault.revoked) return
        try { context.startForegroundService(android.content.Intent(context, ConnectionService::class.java)) }
        catch (error: Exception) { backgroundUnavailable(error.message ?: "Android izin vermedi.") }
    }
    fun connection(): Map<String, Any?> {
        val credentials = try { vault.credentials() } catch (_: Exception) {
            lastError = "Eşleştirme anahtarı okunamadı; cihazı yeniden eşleştir."
            null
        }
        val power = context.getSystemService(PowerManager::class.java)
        return mapOf("paired" to (credentials != null), "connected" to (connected && credentials != null && !vault.revoked),
            "revoked" to vault.revoked,
            "background" to vault.background, "backgroundRunning" to backgroundRunning, "notifications" to notificationsAllowed(),
            "batteryExempt" to power.isIgnoringBatteryOptimizations(context.packageName),
            "serverName" to credentials?.optString("serverName"), "url" to credentials?.optString("url"),
            "identity" to credentials?.let { DurableLocalState.identity(it) }, "serverId" to credentials?.optString("serverId"),
            "deviceId" to credentials?.optString("deviceId"), "lastSyncAt" to vault.lastSyncAt, "cacheFresh" to connected,
            "components" to currentSnapshot.optJSONObject("components")?.asMap(),
            "lastError" to lastError)
    }
    fun notificationsAllowed() = context.getSystemService(android.app.NotificationManager::class.java).areNotificationsEnabled() &&
        (Build.VERSION.SDK_INT < 33 || context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED)
    fun notificationsAuthorized() = !vault.revoked && notificationsAllowed()
    fun notificationPermissionChanged() { publishConnection(); LocalNotifications.reconcile(context, currentSnapshot) }
    @Volatile private var notificationScopedIdentity: String? = null
    @Volatile private var notificationDeviceId: String? = null
    @Volatile private var notificationPreferences = JSONObject().put("global", false)
    fun notificationIdentity(): String? = notificationDeviceId
    private fun publishConnection() { emit("connection", connection()) }

    private fun submit(executor: java.util.concurrent.Executor, complete: (Any?, Throwable?) -> Unit, operation: () -> Any?) {
        try {
            executor.execute {
                try { val result = operation(); main.post { complete(result, null) } }
                catch (error: Exception) { main.post { complete(null, error) } }
            }
        } catch (_: java.util.concurrent.RejectedExecutionException) {
            main.post { complete(null, ApiFailure("busy", "İşlem kuyruğu dolu. Biraz bekleyip yeniden dene.")) }
        }
    }
    fun execute(operation: () -> Any?, complete: (Any?, Throwable?) -> Unit) = submit(worker, complete, operation)
    fun executePairing(operation: () -> Any?, complete: (Any?, Throwable?) -> Unit) = submit(pairing, complete, operation)
    fun discover(enabled: Boolean) = nearby.setEnabled(enabled || active)
    private fun networkChanged() {
        main.removeCallbacks(networkUpdate)
        main.postDelayed(networkUpdate, 500)
    }
    private fun rediscovered(computer: NearbyComputer) {
        synchronized(this) {
            val saved = vault.credentials() ?: return
            if (vault.revoked || saved.optString("serverId") != computer.id || saved.getString("url") == computer.url ||
                saved.getString("fingerprint") != computer.fingerprint) return
            val now = android.os.SystemClock.elapsedRealtime()
            if (rediscoveryAttempts[computer.url]?.let { now - it < 30_000 } == true) return
            // One newest candidate, not an executor task per unauthenticated announcement.
            rediscoveryCandidate = computer
            if (rediscoveryBusy.compareAndSet(false, true)) scheduleRediscovery()
        }
    }
    private fun scheduleRediscovery() {
        rediscovery.schedule(Runnable { probeRediscovered() },
            (nextRediscoveryAt - android.os.SystemClock.elapsedRealtime()).coerceAtLeast(0), TimeUnit.MILLISECONDS)
    }
    private fun probeRediscovered() {
        try {
            val state = synchronized(this) {
                val computer = rediscoveryCandidate ?: return
                rediscoveryCandidate = null
                val saved = vault.credentials() ?: return
                if (vault.revoked || saved.optString("serverId") != computer.id || saved.getString("url") == computer.url ||
                    saved.getString("fingerprint") != computer.fingerprint) return
                val now = android.os.SystemClock.elapsedRealtime()
                if (rediscoveryAttempts[computer.url]?.let { now - it < 30_000 } == true) return
                nextRediscoveryAt = now + 5_000
                rediscoveryAttempts.remove(computer.url); rediscoveryAttempts[computer.url] = now
                if (rediscoveryAttempts.size > 16) rediscoveryAttempts.remove(rediscoveryAttempts.keys.first())
                Triple(generation, saved, computer)
            }
            // Separate executor and client; identity probing never attaches credentials.
            val http = pinnedClient(state.second.getString("certificate"), state.second.getString("fingerprint"))
                .newBuilder().connectTimeout(5, TimeUnit.SECONDS).readTimeout(5, TimeUnit.SECONDS).callTimeout(8, TimeUnit.SECONDS).build()
            val origin = validateOrigin(state.third.url)
            val identity = http.newCall(Request.Builder().url("$origin/v1/identity").build()).execute().use { parseResponse(it) }
            if (identity.optInt("version") != 1 || !ComputerTrust.sameIdentity(state.third.id, state.second.getString("fingerprint"),
                    identity.optString("serverId"), identity.optString("fingerprint"))) return
            synchronized(this) {
                if (state.first != generation || vault.revoked) return
                val saved = vault.credentials() ?: return
                if (saved.optString("serverId") != state.third.id || saved.getString("fingerprint") != state.third.fingerprint ||
                    saved.getString("certificate") != state.second.getString("certificate")) return
                saved.put("url", origin); vault.saveCredentials(saved)
                socket?.cancel(); socket = null; connecting = false; connected = false
                if (active) openSocket(++generation)
                publishConnection()
            }
        } catch (_: Exception) { /* An untrusted announcement never replaces a verified address. */ }
        finally {
            synchronized(this) {
                if (rediscoveryCandidate == null) rediscoveryBusy.set(false)
                else scheduleRediscovery()
            }
        }
    }
    private fun discoveryClient(fingerprint: String): OkHttpClient {
        require(fingerprint.matches(Regex("[0-9a-f]{64}"))) { "Bilgisayar parmak izi geçersiz." }
        fun matches(certificate: java.security.cert.Certificate): Boolean = ComputerTrust.matchesFingerprint(certificate.encoded, fingerprint)
        val trust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) = throw java.security.cert.CertificateException("İstemci kabul edilmiyor.")
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                val certificate = chain?.firstOrNull() ?: throw java.security.cert.CertificateException("Sertifika yok.")
                certificate.checkValidity()
                if (!matches(certificate)) throw java.security.cert.CertificateException("Keşfedilen bilgisayarın TLS kimliği uyuşmuyor.")
            }
        }
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), SecureRandom()) }
        return OkHttpClient.Builder().sslSocketFactory(tls.socketFactory, trust).hostnameVerifier { _, session ->
            try { matches(session.peerCertificates.first()) } catch (_: Exception) { false }
        }.followRedirects(false).followSslRedirects(false).connectTimeout(8, TimeUnit.SECONDS).callTimeout(15, TimeUnit.SECONDS).build()
    }
    private fun JSONObject.pairString(key: String): String = get(key) as? String
        ?: throw ApiFailure("invalid_response", "Eşleştirme yanıtı geçersiz.")
    private fun requirePairVersion(value: JSONObject) {
        if (value.opt("version") != 2) throw ApiFailure("pair_version", "Bilgisayar güvenli eşleştirme sürümünü desteklemiyor.")
    }
    private fun pairResponse(ticket: Int, http: OkHttpClient, request: Request): JSONObject {
        val call = synchronized(this) {
            if (ticket != pairRevision) throw ApiFailure("pair_cancelled", "Eşleştirme iptal edildi.")
            http.newCall(request).also { pairCall = it }
        }
        try {
            return call.execute().use { response ->
                // Remote error text/codes may echo native secrets; never forward them to Dart.
                if (!response.isSuccessful) throw ApiFailure("pair_rejected", "Bilgisayar eşleştirme isteğini reddetti. Yeniden başlat veya bilgisayardaki isteği kontrol et.")
                parseResponse(response)
            }
        }
        finally { synchronized(this) { if (pairCall === call) pairCall = null } }
    }
    fun pairRequest(computerId: String, name: String, background: Boolean): Map<String, Any?> {
        val ticket = synchronized(this) {
            pairCall?.cancel(); pairCall = null
            pendingClient?.dispatcher?.cancelAll(); pendingPair = null; pendingClient = null; ++pairRevision
        }
        try {
            val computer = nearby.computer(computerId) ?: throw ApiFailure("computer_lost", "Bilgisayar artık ağda görünmüyor. Arama sürüyor; tekrar seç.")
            val url = validateOrigin(computer.url)
            val identity = pairResponse(ticket, discoveryClient(computer.fingerprint), Request.Builder().url("$url/v1/identity").build())
            if (identity.optInt("version") != 1 || !ComputerTrust.sameIdentity(computer.id, computer.fingerprint, identity.optString("serverId"), identity.optString("fingerprint")))
                throw ApiFailure("identity_changed", "Bilgisayarın keşif ve TLS kimliği uyuşmuyor. Eşleştirme durduruldu.")
            val certificate = identity.pairString("certificate")
            val serverName = identity.pairString("serverName")
            val http = pinnedClient(certificate, computer.fingerprint)
            synchronized(this) {
                if (ticket != pairRevision) throw ApiFailure("pair_cancelled", "Eşleştirme iptal edildi.")
                pendingClient = http
            }
            val clientSecret = ByteArray(32).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
            val body = JSONObject().put("name", name.trim().take(100).ifEmpty { Build.MODEL })
                .put("clientCommitment", ComputerTrust.clientCommitment(computer.fingerprint, clientSecret))
            val response = pairResponse(ticket, http, Request.Builder().url("$url/v1/pair/request").post(body.toString().toRequestBody(JSON)).build())
            requirePairVersion(response)
            // Capture every commitment field once, before releasing the client secret.
            val commitment = ComputerTrust.ServerCommitment(computer.fingerprint, response.pairString("requestId"),
                response.pairString("claimSecret"), response.pairString("serverCommitment"))
            val expiresAt = response.pairString("expiresAt")
            if (!java.time.Instant.parse(expiresAt).isAfter(java.time.Instant.now()))
                throw ApiFailure("pair_expired", "Eşleştirme isteğinin süresi doldu.")
            val revealBody = JSONObject().put("requestId", commitment.requestId).put("claimSecret", commitment.claimSecret).put("clientSecret", clientSecret)
            // pairResponse atomically checks cancellation and registers the cancellable call.
            val reveal = pairResponse(ticket, http, Request.Builder().url("$url/v1/pair/reveal").post(revealBody.toString().toRequestBody(JSON)).build())
            requirePairVersion(reveal)
            val code = try { commitment.verifiedCode(clientSecret, reveal.pairString("serverSecret"), reveal.pairString("verificationCode")) }
            catch (error: IllegalArgumentException) { throw ApiFailure("verification_mismatch", "Bilgisayarın eşleştirme taahhüdü veya kodu doğrulanamadı. Eşleştirme durduruldu.") }
            val pending = JSONObject().put("requestId", commitment.requestId).put("claimSecret", commitment.claimSecret)
                .put("verificationCode", code).put("expiresAt", expiresAt).put("url", url).put("serverId", computer.id)
                .put("serverName", serverName).put("fingerprint", computer.fingerprint).put("certificate", certificate).put("backgroundOptIn", background)
            return synchronized(this) {
                if (ticket != pairRevision) throw ApiFailure("pair_cancelled", "Eşleştirme iptal edildi.")
                if (!java.time.Instant.parse(expiresAt).isAfter(java.time.Instant.now()))
                    throw ApiFailure("pair_expired", "Eşleştirme isteğinin süresi doldu.")
                pendingPair = pending
                pairPublic(pending)
            }
        } catch (error: Exception) {
            synchronized(this) { if (ticket == pairRevision) { pendingPair = null; pendingClient = null } }
            if (error is ApiFailure) throw error
            throw ApiFailure("invalid_response", "Güvenli eşleştirme tamamlanamadı. Bilgisayarın kimliğini ve ağ bağlantısını kontrol et.")
        }
    }
    private fun pairPublic(value: JSONObject) = mapOf("requestId" to value.getString("requestId"), "verificationCode" to value.getString("verificationCode"),
        "expiresAt" to value.get("expiresAt"), "serverName" to value.getString("serverName"), "fingerprint" to value.getString("fingerprint"))
    @Synchronized fun pairCancel() { pairRevision++; pendingPair = null; pairCall?.cancel(); pairCall = null; pendingClient?.dispatcher?.cancelAll(); pendingClient = null }
    fun pairPoll(): Map<String, Any?> {
        val (ticket, pending, http) = synchronized(this) { Triple(pairRevision, pendingPair ?: return mapOf("status" to "expired"), pendingClient!!) }
        if (java.time.Instant.parse(pending.getString("expiresAt")).isBefore(java.time.Instant.now())) {
            synchronized(this) { if (ticket == pairRevision) { pendingPair = null; pendingClient = null } }
            return mapOf("status" to "expired")
        }
        val body = JSONObject().put("requestId", pending.getString("requestId")).put("claimSecret", pending.getString("claimSecret"))
        val result = pairResponse(ticket, http, Request.Builder().url("${pending.getString("url")}/v1/pair/claim").post(body.toString().toRequestBody(JSON)).build())
        synchronized(this) {
            if (ticket != pairRevision || pendingPair !== pending) throw ApiFailure("pair_cancelled", "Eşleştirme değişti; eski yanıt uygulanmadı.")
            when (result.getString("status")) {
                "approved" -> {
                    if (result.getString("serverId") != pending.getString("serverId")) throw ApiFailure("identity_changed", "Onaylayan bilgisayar kimliği değişti.")
                    val saved = JSONObject().put("url", pending.getString("url")).put("certificate", pending.getString("certificate"))
                        .put("fingerprint", pending.getString("fingerprint")).put("serverId", pending.getString("serverId"))
                        .put("serverName", pending.getString("serverName")).put("deviceId", result.getString("deviceId")).put("token", result.getString("token"))
                    installPair(saved, http)
                    vault.background = pending.optBoolean("backgroundOptIn")
                    if (vault.background && activityVisible) main.post { startBackgroundIfAllowed() }
                    pendingPair = null; pendingClient = null
                }
                "denied", "expired" -> { pendingPair = null; pendingClient = null }
                "pending" -> {}
                else -> throw ApiFailure("invalid_response", "Eşleştirme durumu tanınmıyor.")
            }
        }
        return mapOf("status" to result.getString("status"))
    }
    @Synchronized private fun installPair(saved: JSONObject, http: OkHttpClient) {
        disconnect(); context.stopService(android.content.Intent(context, ConnectionService::class.java))
        client?.dispatcher?.cancelAll(); LocalNotifications.cancelAll(context)
        vault.installCredentials(saved)
        notificationDeviceId = saved.getString("deviceId")
        notificationScopedIdentity = DurableLocalState.identity(saved)
        notificationPreferences = JSONObject()
        currentSnapshot = LocalVault.emptySnapshot()
        acceptedInteractions.clear()
        emit("snapshot", currentSnapshot); client = http; lastError = null; connect()
    }

    fun requestAsync(method: String, path: String, body: Map<*, *>? = null, expectedIdentity: String? = null, complete: (Any?, Throwable?) -> Unit) {
        val critical = path == "/v1/commands" && body?.get("action") in setOf("interaction.respond", "session.abort")
        val ticket = synchronized(this) {
            if (expectedIdentity != null && expectedIdentity != notificationDeviceId) {
                main.post { complete(null, ApiFailure("connection_changed", "Bilgisayar eşleştirmesi değişti; eski cevap gönderilmedi.")) }
                return
            }
            generation
        }
        submit(if (critical) replies else requests, complete) { request(method, path, body, ticket) }
    }

    private fun parseBundle(raw: String): JSONObject {
        val text = raw.trim()
        require(raw.length <= 65_536) { "Eşleştirme verisi çok büyük." }
        val value = if (text.startsWith("omputer://")) {
            val uri = android.net.Uri.parse(text)
            require(uri.host == "pair") { "Geçersiz eşleştirme bağlantısı." }
            val encoded = uri.getQueryParameter("data") ?: throw ApiFailure("invalid_bundle", "Eşleştirme verisi eksik.")
            String(Base64.decode(encoded, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING), Charsets.UTF_8)
        } else text
        require(value.length <= 32_768) { "Eşleştirme verisi çok büyük." }
        return JSONObject(value).also {
            require(it.optInt("version") == 1) { "Bu eşleştirme sürümü desteklenmiyor." }
            validateOrigin(it.getString("url"))
            require(it.getString("code").length in 16..512) { "Eşleştirme kodu geçersiz." }
            if (it.has("expiresAt")) require(java.time.Instant.parse(it.getString("expiresAt")).isAfter(java.time.Instant.now())) { "Eşleştirme kodunun süresi doldu." }
        }
    }
    fun previewBundle(raw: String): Map<String, Any?> {
        val bundle = parseBundle(raw)
        pinnedClient(bundle.getString("certificate"), bundle.getString("fingerprint"))
        return mapOf("serverId" to bundle.optString("serverId").ifBlank { null },
            "serverName" to bundle.optString("serverName").ifBlank { null }, "url" to validateOrigin(bundle.getString("url")),
            "fingerprint" to bundle.getString("fingerprint"), "expiresAt" to bundle.optString("expiresAt").ifBlank { null },
            "existingPair" to (vault.credentials() != null))
    }
    private fun validateOrigin(url: String): String {
        val uri = URI(url)
        require(uri.scheme == "https" && !uri.host.isNullOrBlank() && uri.userInfo == null &&
            uri.fragment == null && uri.query == null && (uri.path.isNullOrEmpty() || uri.path == "/")) {
            "PC adresi https://adres:port biçiminde olmalı."
        }
        return url.trimEnd('/')
    }
    private fun pinnedClient(encodedCertificate: String, fingerprint: String): OkHttpClient {
        val der = Base64.decode(encodedCertificate, Base64.DEFAULT)
        val actual = MessageDigest.getInstance("SHA-256").digest(der).joinToString("") { "%02x".format(it) }
        require(MessageDigest.isEqual(actual.toByteArray(), fingerprint.lowercase().toByteArray())) {
            "PC sertifikası eşleştirme parmak iziyle uyuşmuyor."
        }
        val certificate = CertificateFactory.getInstance("X.509").generateCertificate(ByteArrayInputStream(der)) as X509Certificate
        certificate.checkValidity()
        val trust = object : X509TrustManager {
            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf(certificate)
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) =
                throw java.security.cert.CertificateException("İstemci sertifikası kabul edilmiyor.")
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {
                val peer = chain?.firstOrNull() ?: throw java.security.cert.CertificateException("PC sertifikası eksik.")
                peer.checkValidity()
                if (!MessageDigest.isEqual(peer.encoded, der)) throw java.security.cert.CertificateException("PC kimliği değişti; yeniden eşleştir.")
            }
        }
        val tls = SSLContext.getInstance("TLS").apply { init(null, arrayOf(trust), SecureRandom()) }
        return OkHttpClient.Builder().sslSocketFactory(tls.socketFactory, trust)
            .hostnameVerifier { _, session ->
                try { MessageDigest.isEqual(session.peerCertificates.first().encoded, der) } catch (_: Exception) { false }
            }.followRedirects(false).followSslRedirects(false).connectTimeout(12, TimeUnit.SECONDS)
            .readTimeout(35, TimeUnit.SECONDS).callTimeout(45, TimeUnit.SECONDS).pingInterval(25, TimeUnit.SECONDS).build()
    }
    private fun credentials() = vault.credentials() ?: throw ApiFailure("not_paired", "Önce PC ile eşleştir.")
    private fun authenticatedClient(): OkHttpClient {
        client?.let { return it }
        val saved = credentials()
        return pinnedClient(saved.getString("certificate"), saved.getString("fingerprint")).also { client = it }
    }
    fun pair(raw: String, name: String): Map<String, Any?> {
        val ticket = synchronized(this) { pairCancel(); pairRevision }
        val bundle = parseBundle(raw)
        val http = pinnedClient(bundle.getString("certificate"), bundle.getString("fingerprint"))
        val url = validateOrigin(bundle.getString("url"))
        val body = JSONObject().put("code", bundle.getString("code")).put("name", name.trim().take(100).ifEmpty { Build.MODEL })
        val request = Request.Builder().url("$url/v1/pair").post(body.toString().toRequestBody(JSON)).build()
        val result = pairResponse(ticket, http, request)
        val saved = JSONObject().put("url", url).put("certificate", bundle.getString("certificate"))
            .put("fingerprint", bundle.getString("fingerprint")).put("deviceId", result.getString("deviceId"))
            .put("token", result.getString("token")).put("serverName", result.getString("serverName"))
        bundle.optString("serverId").takeIf { it.isNotBlank() }?.let { saved.put("serverId", it) }
        return synchronized(this) {
            if (ticket != pairRevision) throw ApiFailure("pair_cancelled", "Eşleştirme iptal edildi; eski onay uygulanmadı.")
            installPair(saved, http)
            mapOf("deviceId" to saved.getString("deviceId"), "serverName" to saved.getString("serverName"), "url" to url)
        }
    }
    private fun parseResponse(response: Response): JSONObject {
        val raw = response.body?.string().orEmpty()
        val value = try { JSONObject(raw) } catch (_: Exception) {
            throw ApiFailure("invalid_response", "PC geçerli bir yanıt göndermedi (${response.code}).")
        }
        if (!response.isSuccessful) {
            val error = value.optJSONObject("error")
            throw ApiFailure(error?.optString("code") ?: "http_${response.code}",
                error?.optString("message") ?: "PC isteği reddetti (${response.code}).")
        }
        return value
    }
    fun request(method: String, path: String, body: Map<*, *>? = null, expectedGeneration: Int? = null, retainCommandError: Boolean = false): Map<String, Any?> {
        require(method in setOf("GET", "POST", "PATCH")) { "Desteklenmeyen istek." }
        require(path.startsWith("/v1/") && !path.contains('\\') && !path.contains('#') && !path.contains('\n')) { "Geçersiz yerel API yolu." }
        val (ticket, saved, http) = synchronized(this) {
            if (expectedGeneration != null && expectedGeneration != generation) throw ApiFailure("connection_changed", "Bağlantı değişti; eski işlem yeni bilgisayara gönderilmedi.")
            if (vault.revoked) throw ApiFailure("device_revoked", "Bu cihazın yetkisi kaldırıldı; yeniden eşleştir.")
            if (path == "/v1/commands" && body?.get("action") == "interaction.respond") {
                val payload = body?.get("payload") as? Map<*, *>
                requirePendingInteraction(payload?.get("interactionId") as? String ?: throw ApiFailure("interaction_missing", "Karar kimliği eksik."))
            }
            Triple(generation, credentials(), authenticatedClient())
        }
        val base = validateOrigin(saved.getString("url"))
        val historyRevision = vault.messagesRevision
        val request = Request.Builder().url(base + path).header("Authorization", "Bearer ${saved.getString("token")}")
        when (method) {
            "GET" -> request.get()
            "POST" -> request.post(JSONObject(body ?: emptyMap<String, Any?>()).toString().toRequestBody(JSON))
            "PATCH" -> request.patch(JSONObject(body ?: emptyMap<String, Any?>()).toString().toRequestBody(JSON))
        }
        val cacheable = method == "GET" && (path.contains("/messages") || path.contains("/files?") || path == "/v1/models")
        val result = try {
            http.newCall(request.build()).execute().use { parseResponse(it) }
        } catch (error: ApiFailure) {
            if (error.code in setOf("unauthorized", "device_revoked")) lost(ticket, error.message, true)
            throw error
        } catch (error: IOException) {
            if (error is javax.net.ssl.SSLException) throw error
            if (!cacheable) throw error
            vault.cachedResponse(path)?.put("cached", true) ?: throw error
        }
        if (path == "/v1/commands" && !retainCommandError) DecisionPolicy.commandError(result)?.let { throw ApiFailure(it.first, it.second) }
        return synchronized(this) {
            if (ticket != generation || vault.revoked) throw ApiFailure("connection_changed", "Bağlantı değişti; eski bilgisayarın yanıtı uygulanmadı.")
            if (ResponseCache.isMessages(path) && historyRevision != vault.messagesRevision) throw ApiFailure("history_changed", "Konuşma dalı değişti; güncel mesajları yeniden aç.")
            if (path == "/v1/commands" && body?.get("action") == "interaction.respond" && DecisionPolicy.finalSuccess(result)) {
                val payload = body?.get("payload") as? Map<*, *>
                val id = payload?.get("interactionId") as? String
                val request = id?.let(::pendingInteraction)
                if (request != null && request.optString("status") == "pending") {
                    val snapshot = shallowCopy(currentSnapshot)
                    acceptedInteractions[request.getString("id")] = if (payload?.get("cancelled") == true) "cancelled" else "resolved"
                    if (acceptedInteractions.size > 256) acceptedInteractions.remove(acceptedInteractions.keys.first())
                    replaceRow(snapshot, "interactions", shallowCopy(request).put("status", if (payload?.get("cancelled") == true) "cancelled" else "resolved"))
                    saveSnapshot(snapshot)
                }
                if (id != null) LocalNotifications.cancelInteraction(context, id)
            }
            if (path == "/v1/snapshot") saveSnapshot(result)
            else if (cacheable && !result.optBoolean("cached")) vault.cacheResponse(path, result)
            result.asMap()
        }
    }
    @Synchronized private fun saveSnapshot(snapshot: JSONObject) {
        val expected = credentials().optString("serverId")
        val actual = snapshot.optString("serverId")
        if (expected.isNotBlank() && actual.isNotBlank() && expected != actual) throw ApiFailure("identity_changed", "Bilgisayar kimliği değişti; eski eşleştirmeyle veri uygulanmadı.")
        if (snapshot.optLong("sequence") < currentSnapshot.optLong("sequence")) return
        val interactions = snapshot.optJSONArray("interactions")
        if (interactions != null && acceptedInteractions.isNotEmpty()) {
            val next = JSONArray()
            for (index in 0 until interactions.length()) interactions.optJSONObject(index)?.let { row ->
                val id = row.optString("id")
                val status = acceptedInteractions[id]
                if (status != null && row.optString("status") == "pending") next.put(shallowCopy(row).put("status", status))
                else next.put(row)
            }
            snapshot.put("interactions", next)
        }
        currentSnapshot = snapshot
        vault.saveSnapshot(snapshot)
        LocalNotifications.reconcile(context, snapshot)
        emit("snapshot", snapshot)
    }
    fun pendingInteraction(id: String): JSONObject? {
        val rows = currentSnapshot.optJSONArray("interactions") ?: return null
        for (index in 0 until rows.length()) rows.optJSONObject(index)?.let { if (it.optString("id") == id) return it }
        return null
    }
    fun requirePendingInteraction(id: String) {
        val request = pendingInteraction(id) ?: throw ApiFailure("interaction_missing", "Bu karar artık kullanılamıyor. Uygulamayı açıp güncel soruyu kontrol et.")
        if (!DecisionPolicy.pending(request)) throw ApiFailure("interaction_expired", "Bu kararın süresi doldu veya zaten yanıtlandı.")
    }

    @Synchronized fun connect() {
        if (vault.revoked) { lastError = "Bu cihazın yetkisi kaldırıldı; yeniden eşleştir."; publishConnection(); return }
        if (active && (connected || connecting)) return
        credentials()
        active = true
        nearby.setEnabled(true)
        reconnect()
    }
    @Synchronized fun reconnect() {
        if (vault.revoked) { connect(); return }
        credentials(); active = true
        nearby.setEnabled(true)
        retry?.let { main.removeCallbacks(it) }; retry = null
        openingCall?.cancel(); openingCall = null
        socket?.cancel(); socket = null; connecting = false; connected = false
        val ticket = ++generation
        publishConnection()
        openSocket(ticket)
    }
    private fun openSocket(ticket: Int) {
        synchronized(this) {
            if (!active || ticket != generation || connecting) return
            connecting = true
        }
        submit(worker, { _, error -> if (error != null) lost(ticket, error.message ?: "Bağlantı başlatılamadı.", false) }) {
            try {
                val (saved, http) = synchronized(this) {
                    if (!active || ticket != generation || vault.revoked) return@submit null
                    Pair(credentials(), authenticatedClient())
                }
                val origin = validateOrigin(saved.getString("url"))
                val bootstrap = http.newCall(Request.Builder().url("$origin/v1/snapshot")
                    .header("Authorization", "Bearer ${saved.getString("token")}").build())
                synchronized(this) {
                    if (!active || ticket != generation || vault.revoked) return@submit null
                    openingCall = bootstrap
                }
                val latest = try { bootstrap.execute().use { parseResponse(it) } }
                finally { synchronized(this) { if (openingCall === bootstrap) openingCall = null } }
                synchronized(this) {
                    if (!active || ticket != generation || vault.revoked) return@submit null
                    saveSnapshot(latest)
                    vault.resetMessages()
                    vault.sequence = latest.getLong("sequence")
                    emit("history_reset", emptyMap<String, Any?>())
                }
                val httpRequest = Request.Builder().url("${origin.replaceFirst("https://", "wss://")}/v1/events?after=${latest.getLong("sequence")}")
                    .header("Authorization", "Bearer ${saved.getString("token")}").build()
                val opened = http.newWebSocket(httpRequest, object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        synchronized(this@LocalConnection) {
                            if (!active || ticket != generation || vault.revoked) { webSocket.cancel(); return }
                            connected = true; connecting = false; lastError = null; retrySeconds = 1
                            submit(replies, { _, _ -> }) { reconcileNativeReplies(); null }
                            publishConnection()
                        }
                    }
                    override fun onMessage(webSocket: WebSocket, text: String) {
                        // Process on OkHttp's reader: don't retain an unbounded queue of replay frames.
                        if (ticket != generation) return
                        try { processEvent(JSONObject(text), ticket) }
                        catch (error: Exception) {
                            // Never advance beyond a frame that could not be applied. Bootstrap
                            // from a new authenticated snapshot instead of continuing on a gap.
                            webSocket.cancel()
                            lost(ticket, "Oturum olayı işlenemedi; bağlantı yenileniyor: ${error.message}", false)
                        }
                    }
                    override fun onFailure(webSocket: WebSocket, error: Throwable, response: Response?) {
                        lost(ticket, if (response?.code == 401) "Cihaz yetkisi kaldırılmış; yeniden eşleştir." else error.message ?: "PC bağlantısı kesildi.", response?.code == 401)
                    }
                    override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, reason) }
                    override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                        val revoked = code == 4401 || reason == "device_revoked"
                        lost(ticket, if (revoked) "Cihaz yetkisi kaldırılmış; yeniden eşleştir." else "PC bağlantısı kapandı.", revoked)
                    }
                })
                synchronized(this) {
                    if (active && ticket == generation) socket = opened
                    else opened.cancel()
                }
            } catch (error: Exception) {
                lost(ticket, error.message ?: "PC’ye bağlanılamadı.", error is ApiFailure && error.code in setOf("unauthorized", "device_revoked"))
            }
        }
    }
    @Synchronized private fun lost(ticket: Int, message: String, revoked: Boolean) {
        if (ticket != generation) return
        val next = ++generation
        openingCall?.cancel(); openingCall = null
        socket?.cancel(); socket = null; connecting = false; connected = false; lastError = message
        retry?.let { main.removeCallbacks(it) }; retry = null
        if (revoked) {
            vault.revoked = true
            client?.dispatcher?.cancelAll()
            active = false; vault.background = false
            context.stopService(android.content.Intent(context, ConnectionService::class.java))
            LocalNotifications.cancelAll(context)
        }
        publishConnection()
        if (!active || revoked) return
        val delay = retrySeconds
        retrySeconds = (retrySeconds * 2).coerceAtMost(30)
        retry = Runnable { synchronized(this) { if (active && next == generation) openSocket(next) } }
        main.postDelayed(retry!!, delay * 1000)
    }
    @Synchronized fun disconnect() {
        active = false; connecting = false; generation++
        retry?.let { main.removeCallbacks(it) }; retry = null
        openingCall?.cancel(); openingCall = null
        socket?.cancel(); socket = null
        connected = false; publishConnection()
        if (!activityVisible) nearby.setEnabled(false)
    }
    @Synchronized fun forget() {
        pairCancel()
        disconnect(); client?.dispatcher?.cancelAll(); client = null
        vault.forget(); lastError = null; LocalNotifications.cancelAll(context)
        notificationDeviceId = null
        notificationScopedIdentity = null
        notificationPreferences = JSONObject().put("global", false)
        currentSnapshot = LocalVault.emptySnapshot()
        acceptedInteractions.clear()
        nearby.setEnabled(activityVisible)
        emit("snapshot", currentSnapshot); publishConnection()
    }

    private fun shallowCopy(value: JSONObject): JSONObject = JSONObject().also { copy -> value.keys().forEach { copy.put(it, value.opt(it)) } }
    private fun replaceRow(snapshot: JSONObject, collection: String, item: JSONObject) {
        val rows = snapshot.optJSONArray(collection) ?: JSONArray()
        val next = JSONArray()
        var replaced = false
        for (index in 0 until rows.length()) {
            val row = rows.optJSONObject(index) ?: continue
            if (row.optString("id") == item.optString("id")) { next.put(item); replaced = true } else next.put(row)
        }
        if (!replaced) next.put(item)
        snapshot.put(collection, next)
    }
    @Synchronized private fun processEvent(event: JSONObject, ticket: Int) {
        if (ticket != generation || vault.revoked) return
        val seq = event.optLong("sequence", 0)
        val type = event.getString("type")
        val data = event.optJSONObject("data") ?: JSONObject()
        if (type == "snapshot") {
            if (seq >= currentSnapshot.optLong("sequence")) saveSnapshot(data)
            if (seq > vault.sequence) vault.sequence = seq
            return
        }
        if (seq > 0 && seq <= vault.sequence) return
        val reset = type == "session.event" && data.optString("type") == "transcript_reset"
        if (seq > 0 && seq <= currentSnapshot.optLong("sequence") && !reset && type !in setOf("notification", "message.upsert", "device.revoked")) {
            vault.sequence = seq
            return
        }
        // Transcript traffic does not mutate the project snapshot. Keep its hot path
        // independent of snapshot JSON parsing and only load histories when opened.
        if (type == "message.upsert") {
            vault.cacheMessage(event.optString("sessionId"), data.optJSONObject("message") ?: data)
            emit("event", event)
            if (seq > 0) vault.sequence = seq
            return
        }
        if (type == "session.event") {
            if (reset) vault.resetMessages(event.optString("sessionId"))
            emit("event", event)
            if (seq > 0) vault.sequence = seq
            return
        }
        run {
            val snapshot = shallowCopy(currentSnapshot)
            var changed = true
            when (type) {
                "operation.updated" -> { reconcileNativeReply(data); changed = false }
                "session.updated" -> replaceRow(snapshot, "sessions", data.optJSONObject("session") ?: data)
                "project.updated" -> replaceRow(snapshot, "projects", data.optJSONObject("project") ?: data)
                "interaction.pending" -> replaceRow(snapshot, "interactions", data.optJSONObject("interaction") ?: data)
                "interaction.resolved" -> {
                    val id = data.optString("id", data.optString("interactionId"))
                    val rows = snapshot.optJSONArray("interactions") ?: JSONArray()
                    val next = JSONArray()
                    for (index in 0 until rows.length()) rows.optJSONObject(index)?.let {
                        next.put(if (it.optString("id") == id) shallowCopy(it).put("status", data.optString("status", "resolved")) else it)
                    }
                    snapshot.put("interactions", next)
                    LocalNotifications.cancelInteraction(context, id)
                }
                "notification" -> { LocalNotifications.post(context, data); changed = false }
                "device.revoked" -> {
                    val current = data.optString("id", data.optString("deviceId")) == credentials().optString("deviceId")
                    data.put("currentDevice", current)
                    val devices = snapshot.optJSONArray("devices") ?: JSONArray()
                    val next = JSONArray()
                    for (index in 0 until devices.length()) devices.optJSONObject(index)?.let {
                        next.put(if (it.optString("id") == data.optString("id", data.optString("deviceId"))) shallowCopy(it).put("revokedAt", event.optString("createdAt")) else it)
                    }
                    snapshot.put("devices", next)
                    if (current) {
                        vault.revoked = true
                        client?.dispatcher?.cancelAll()
                        lastError = "Bu telefonun PC yetkisi kaldırıldı."; vault.background = false
                        context.stopService(android.content.Intent(context, ConnectionService::class.java))
                        disconnect(); LocalNotifications.cancelAll(context)
                    }
                }
                else -> changed = false
            }
            if (changed) { snapshot.put("sequence", seq); saveSnapshot(snapshot) }
        }
        emit("event", event)
        if (seq > 0) vault.sequence = seq
    }
    private val JSON = "application/json; charset=utf-8".toMediaType()
}
