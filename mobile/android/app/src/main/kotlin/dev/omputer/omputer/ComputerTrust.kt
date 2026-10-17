package dev.omputer.omputer

import java.security.MessageDigest

/** Discovery is a locator, never authority to replace a previously paired certificate. */
internal object ComputerTrust {
    fun matchesFingerprint(der: ByteArray, expected: String): Boolean {
        if (!expected.matches(Regex("[0-9a-fA-F]{64}"))) return false
        val actual = MessageDigest.getInstance("SHA-256").digest(der).joinToString("") { "%02x".format(it) }
        return MessageDigest.isEqual(actual.toByteArray(Charsets.US_ASCII), expected.lowercase().toByteArray(Charsets.US_ASCII))
    }
    fun sameIdentity(discoveredId: String, discoveredFingerprint: String, identityId: String, identityFingerprint: String) =
        discoveredId.isNotBlank() && discoveredId == identityId && discoveredFingerprint == identityFingerprint
    private val hex = Regex("[0-9a-f]{64}")

    private fun requireHex(value: String) { require(hex.matches(value)) { "Geçersiz eşleştirme özeti." } }
    private fun requireRequestId(value: String) {
        require(java.util.UUID.fromString(value).toString() == value) { "Geçersiz eşleştirme kimliği." }
    }
    private fun digest(domain: String, vararg fields: String): ByteArray {
        // All callers validate their typed fields; this alphabet cannot escape a JSON string.
        require(fields.all { it.matches(Regex("[a-z0-9-]+")) })
        val canonical = (listOf(domain) + fields).joinToString(",", "[", "]") { "\"$it\"" }
        return MessageDigest.getInstance("SHA-256").digest(canonical.toByteArray(Charsets.US_ASCII))
    }
    private fun ByteArray.hex() = joinToString("") { "%02x".format(it) }
    private fun equal(left: String, right: String) =
        MessageDigest.isEqual(left.toByteArray(Charsets.US_ASCII), right.toByteArray(Charsets.US_ASCII))

    fun clientCommitment(fingerprint: String, clientSecret: String): String {
        requireHex(fingerprint); requireHex(clientSecret)
        return digest("omputer-client-v2", fingerprint, clientSecret).hex()
    }
    fun serverCommitment(fingerprint: String, requestId: String, claimSecret: String, serverSecret: String): String {
        requireHex(fingerprint); requireRequestId(requestId); requireHex(claimSecret); requireHex(serverSecret)
        return digest("omputer-server-v2", fingerprint, requestId, claimSecret, serverSecret).hex()
    }
    fun verificationCode(fingerprint: String, requestId: String, clientSecret: String, serverSecret: String): String {
        requireHex(fingerprint); requireRequestId(requestId); requireHex(clientSecret); requireHex(serverSecret)
        val hash = digest("omputer-sas-v2", fingerprint, requestId, clientSecret, serverSecret)
        var value = 0L
        for (index in 0..3) value = (value shl 8) or (hash[index].toLong() and 255)
        return (value % 1_000_000).toString().padStart(6, '0')
    }

    /** Captured before revealing the client secret. No mutable response object is retained. */
    class ServerCommitment(
        private val fingerprint: String,
        val requestId: String,
        val claimSecret: String,
        private val commitment: String,
    ) {
        init { requireHex(fingerprint); requireRequestId(requestId); requireHex(claimSecret); requireHex(commitment) }

        fun verifiedCode(clientSecret: String, serverSecret: String, advertisedCode: String): String {
            require(equal(commitment, serverCommitment(fingerprint, requestId, claimSecret, serverSecret))) {
                "Bilgisayarın eşleştirme taahhüdü değişti. Eşleştirme durduruldu."
            }
            val code = verificationCode(fingerprint, requestId, clientSecret, serverSecret)
            require(advertisedCode.matches(Regex("[0-9]{6}")) && equal(code, advertisedCode)) {
                "Eşleştirme kodu doğrulanamadı. Eşleştirme durduruldu."
            }
            return code
        }
    }
}
