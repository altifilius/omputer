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
    private val worker = Executors.newSingleThreadExecutor()
    private val requests = Executors.newFixedThreadPool(4)
    private val replies = Executors.newSingleThreadExecutor()
    private val pairing = Executors.newSingleThreadExecutor()
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
    private val listeners = CopyOnWriteArraySet<(Map<String, Any?>) -> Unit>()
    private var socket: WebSocket? = null
    private var client: OkHttpClient? = null
    @Volatile private var generation = 0
    @Volatile private var active = false
    @Volatile private var connected = false
    @Volatile private var lastError: String? = null
    @Volatile var activityVisible = false
    private var retrySeconds = 1L
    private var pendingNavigation: Map<String, Any?>? = null
    var onConnectionChanged: (() -> Unit)? = null

    @Synchronized fun initialize(application: Context) {
        if (::context.isInitialized) return
        context = application.applicationContext
        vault = LocalVault(context)
        LocalNotifications.initialize(context)
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
        val event = mapOf("type" to type, "data" to data)
        val ticket = generation
        main.post { if (type !in setOf("connection", "snapshot", "event") || ticket == generation) listeners.forEach { it(event) } }
    }
    fun navigate(data: Map<String, Any?>) {
        val event = mapOf("type" to "navigate", "data" to data)
        synchronized(this) { if (listeners.isEmpty()) pendingNavigation = event }
        emit("navigate", data)
    }
    fun snapshot(): Map<String, Any?> = vault.snapshot().asMap()
    fun preferences() = mapOf("theme" to vault.theme)
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
        val credentials = try { vault.credentials() } catch (error: Exception) {
            lastError = "Eşleştirme anahtarı okunamadı; cihazı yeniden eşleştir."
            null
        }
        val power = context.getSystemService(PowerManager::class.java)
        return mapOf("paired" to (credentials != null), "connected" to connected,
            "background" to vault.background, "backgroundRunning" to backgroundRunning, "notifications" to notificationsAllowed(),
            "batteryExempt" to power.isIgnoringBatteryOptimizations(context.packageName),
            "serverName" to credentials?.optString("serverName"), "url" to credentials?.optString("url"),
            "lastError" to lastError)
    }
    fun notificationsAllowed() = Build.VERSION.SDK_INT < 33 ||
        context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    fun notificationsAuthorized() = !vault.revoked && notificationsAllowed()
    private fun publishConnection() { emit("connection", connection()); main.post { onConnectionChanged?.invoke() } }

    fun execute(operation: () -> Any?, complete: (Any?, Throwable?) -> Unit) {
        worker.execute {
            try { val result = operation(); main.post { complete(result, null) } }
            catch (error: Exception) { main.post { complete(null, error) } }
        }
    }
    fun executePairing(operation: () -> Any?, complete: (Any?, Throwable?) -> Unit) {
        pairing.execute {
            try { val result = operation(); main.post { complete(result, null) } }
            catch (error: Exception) { main.post { complete(null, error) } }
        }
    }
    fun discover(enabled: Boolean) = nearby.setEnabled(enabled || active)
    private fun networkChanged() {
        nearby.networkChanged()
        worker.execute {
            synchronized(this) {
                if (active && !vault.revoked) { socket?.cancel(); socket = null; connected = false; val ticket = ++generation; publishConnection(); openSocket(ticket) }
            }
        }
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
                socket?.cancel(); socket = null; connected = false
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
        vault.forget(); vault.saveCredentials(saved)
        emit("snapshot", LocalVault.emptySnapshot().asMap()); client = http; lastError = null; connect()
    }

    fun requestAsync(method: String, path: String, body: Map<*, *>? = null, complete: (Any?, Throwable?) -> Unit) {
        val critical = path == "/v1/commands" && body?.get("action") in setOf("interaction.respond", "session.abort")
        (if (critical) replies else requests).execute {
            try { val result = request(method, path, body); main.post { complete(result, null) } }
            catch (error: Exception) { main.post { complete(null, error) } }
        }
    }

    private fun parseBundle(raw: String): JSONObject {
        val text = raw.trim()
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
        }
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
        val bundle = parseBundle(raw)
        val http = pinnedClient(bundle.getString("certificate"), bundle.getString("fingerprint"))
        val url = validateOrigin(bundle.getString("url"))
        val body = JSONObject().put("code", bundle.getString("code")).put("name", name.trim().take(100).ifEmpty { Build.MODEL })
        val request = Request.Builder().url("$url/v1/pair").post(body.toString().toRequestBody(JSON)).build()
        val result = http.newCall(request).execute().use { parseResponse(it) }
        val saved = JSONObject().put("url", url).put("certificate", bundle.getString("certificate"))
            .put("fingerprint", bundle.getString("fingerprint")).put("deviceId", result.getString("deviceId"))
            .put("token", result.getString("token")).put("serverName", result.getString("serverName"))
        bundle.optString("serverId").takeIf { it.isNotBlank() }?.let { saved.put("serverId", it) }
        pairCancel()
        installPair(saved, http)
        return mapOf("deviceId" to saved.getString("deviceId"), "serverName" to saved.getString("serverName"), "url" to url)
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
    fun request(method: String, path: String, body: Map<*, *>? = null): Map<String, Any?> {
        require(method in setOf("GET", "POST", "PATCH")) { "Desteklenmeyen istek." }
        require(path.startsWith("/v1/") && !path.contains('\\') && !path.contains('#') && !path.contains('\n')) { "Geçersiz yerel API yolu." }
        val (ticket, saved, http) = synchronized(this) {
            if (vault.revoked) throw ApiFailure("device_revoked", "Bu cihazın yetkisi kaldırıldı; yeniden eşleştir.")
            Triple(generation, credentials(), authenticatedClient())
        }
        val base = validateOrigin(saved.getString("url"))
        val request = Request.Builder().url(base + path).header("Authorization", "Bearer ${saved.getString("token")}")
        when (method) {
            "GET" -> request.get()
            "POST" -> request.post(JSONObject(body ?: emptyMap<String, Any?>()).toString().toRequestBody(JSON))
            "PATCH" -> request.patch(JSONObject(body ?: emptyMap<String, Any?>()).toString().toRequestBody(JSON))
        }
        val cacheable = method == "GET" && (path.contains("/messages") || path.contains("/files?") || path == "/v1/models")
        val result = try {
            http.newCall(request.build()).execute().use { parseResponse(it) }
        } catch (error: IOException) {
            if (error is javax.net.ssl.SSLException) throw error
            if (!cacheable) throw error
            vault.cachedResponse(path)?.put("cached", true) ?: throw error
        }
        return synchronized(this) {
            if (ticket != generation || vault.revoked) throw ApiFailure("connection_changed", "Bağlantı değişti; eski bilgisayarın yanıtı uygulanmadı.")
            if (path == "/v1/snapshot") saveSnapshot(result)
            else if (cacheable && !result.optBoolean("cached")) vault.cacheResponse(path, result)
            result.asMap()
        }
    }
    @Synchronized private fun saveSnapshot(snapshot: JSONObject) {
        if (snapshot.optLong("sequence") < vault.snapshot().optLong("sequence")) return
        vault.saveSnapshot(snapshot)
        LocalNotifications.reconcile(context, snapshot)
        emit("snapshot", snapshot.asMap())
    }

    @Synchronized fun connect() {
        if (vault.revoked) { lastError = "Bu cihazın yetkisi kaldırıldı; yeniden eşleştir."; publishConnection(); return }
        if (active && socket != null) return
        credentials()
        active = true
        nearby.setEnabled(true)
        val ticket = ++generation
        openSocket(ticket)
    }
    private fun openSocket(ticket: Int) {
        worker.execute {
            if (!active || ticket != generation) return@execute
            try {
                val saved = credentials()
                val origin = validateOrigin(saved.getString("url")).replaceFirst("https://", "wss://")
                val httpRequest = Request.Builder().url("$origin/v1/events?after=${vault.sequence}")
                    .header("Authorization", "Bearer ${saved.getString("token")}").build()
                socket = authenticatedClient().newWebSocket(httpRequest, object : WebSocketListener() {
                    override fun onOpen(webSocket: WebSocket, response: Response) {
                        worker.execute {
                            if (ticket != generation) { webSocket.close(1000, "superseded"); return@execute }
                            connected = true; lastError = null; retrySeconds = 1
                            publishConnection()
                            requestAsync("GET", "/v1/snapshot") { _, error ->
                                if (error != null && ticket == generation) { lastError = error.message; publishConnection() }
                            }
                        }
                    }
                    override fun onMessage(webSocket: WebSocket, text: String) {
                        worker.execute {
                            if (ticket != generation) return@execute
                            try { processEvent(JSONObject(text), ticket) }
                            catch (error: Exception) { lastError = "Oturum olayı işlenemedi: ${error.message}"; publishConnection() }
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
            } catch (error: Exception) { lost(ticket, error.message ?: "PC’ye bağlanılamadı.", false) }
        }
    }
    private fun lost(ticket: Int, message: String, revoked: Boolean) {
        worker.execute {
            if (ticket != generation) return@execute
            connected = false; socket = null; lastError = message
            publishConnection()
            if (revoked) {
                vault.revoked = true
                active = false; vault.background = false
                context.stopService(android.content.Intent(context, ConnectionService::class.java))
                LocalNotifications.cancelAll(context); publishConnection(); return@execute
            }
            if (!active) return@execute
            val delay = retrySeconds
            retrySeconds = (retrySeconds * 2).coerceAtMost(30)
            main.postDelayed({ if (active && ticket == generation) openSocket(ticket) }, delay * 1000)
        }
    }
    @Synchronized fun disconnect() {
        active = false; generation++; socket?.close(1000, "local disconnect"); socket = null
        connected = false; publishConnection()
        if (!activityVisible) nearby.setEnabled(false)
    }
    @Synchronized fun forget() {
        pairCancel()
        disconnect(); client?.dispatcher?.cancelAll(); client = null
        vault.forget(); lastError = null; LocalNotifications.cancelAll(context)
        nearby.setEnabled(activityVisible)
        emit("snapshot", vault.snapshot().asMap()); publishConnection()
    }

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
            if (seq >= vault.snapshot().optLong("sequence")) saveSnapshot(data)
            if (seq > vault.sequence) vault.sequence = seq
            return
        }
        if (seq > 0 && seq <= vault.sequence) return
        val reset = type == "session.event" && data.optString("type") == "transcript_reset"
        if (seq > 0 && seq <= vault.snapshot().optLong("sequence") && !reset && type !in setOf("notification", "message.upsert", "device.revoked")) {
            vault.sequence = seq
            return
        }
        run {
            val snapshot = vault.snapshot()
            var changed = true
            when (type) {
                "session.updated" -> replaceRow(snapshot, "sessions", data.optJSONObject("session") ?: data)
                "project.updated" -> replaceRow(snapshot, "projects", data.optJSONObject("project") ?: data)
                "interaction.pending" -> replaceRow(snapshot, "interactions", data.optJSONObject("interaction") ?: data)
                "interaction.resolved" -> {
                    val id = data.optString("id", data.optString("interactionId"))
                    val rows = snapshot.optJSONArray("interactions") ?: JSONArray()
                    for (index in 0 until rows.length()) rows.optJSONObject(index)?.let { if (it.optString("id") == id) it.put("status", data.optString("status", "resolved")) }
                    LocalNotifications.cancelInteraction(context, id)
                }
                "session.event" -> {
                    if (data.optString("type") == "transcript_reset") vault.resetMessages(event.optString("sessionId"))
                    changed = false
                }
                "message.upsert" -> {
                    val message = data.optJSONObject("message") ?: data
                    vault.cacheMessage(event.optString("sessionId"), message)
                    changed = false
                }
                "notification" -> { LocalNotifications.post(context, data); changed = false }
                "device.revoked" -> {
                    val current = data.optString("id", data.optString("deviceId")) == credentials().optString("deviceId")
                    data.put("currentDevice", current)
                    val devices = snapshot.optJSONArray("devices") ?: JSONArray()
                    for (index in 0 until devices.length()) devices.optJSONObject(index)?.let {
                        if (it.optString("id") == data.optString("id", data.optString("deviceId"))) it.put("revokedAt", event.optString("createdAt"))
                    }
                    if (current) {
                        vault.revoked = true
                        lastError = "Bu telefonun PC yetkisi kaldırıldı."; vault.background = false
                        context.stopService(android.content.Intent(context, ConnectionService::class.java))
                        disconnect(); LocalNotifications.cancelAll(context)
                    }
                }
                else -> changed = false
            }
            if (changed) { snapshot.put("sequence", seq); saveSnapshot(snapshot) }
        }
        emit("event", event.asMap())
        if (seq > 0) vault.sequence = seq
    }
    private val JSON = "application/json; charset=utf-8".toMediaType()
}
