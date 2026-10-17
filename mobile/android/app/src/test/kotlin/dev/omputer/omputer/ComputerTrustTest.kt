package dev.omputer.omputer

import org.junit.Assert.*
import org.junit.Test

class ComputerTrustTest {
    @Test fun exactAdvertisedCertificateIsRequired() {
        val emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        assertTrue(ComputerTrust.matchesFingerprint(byteArrayOf(), emptyHash))
        assertFalse(ComputerTrust.matchesFingerprint(byteArrayOf(1), emptyHash))
        assertFalse(ComputerTrust.matchesFingerprint(byteArrayOf(), "invalid"))
    }
    @Test fun changingAddressCannotChangeServerOrPin() {
        assertTrue(ComputerTrust.sameIdentity("pc-a", "pin-a", "pc-a", "pin-a"))
        assertFalse(ComputerTrust.sameIdentity("pc-a", "pin-a", "pc-b", "pin-a"))
        assertFalse(ComputerTrust.sameIdentity("pc-a", "pin-a", "pc-a", "pin-b"))
        assertFalse(ComputerTrust.sameIdentity("", "pin-a", "", "pin-a"))
    }
    private val fingerprint = "ab".repeat(32)
    private val clientSecret = "12".repeat(32)
    private val requestId = "c3f39110-349d-4c92-a49e-977891949688"
    private val claimSecret = "34".repeat(32)
    private val serverSecret = "56".repeat(32)
    private val commitment = "1829f7be07578a344d9e37d85f06b2c51fa7cc62bb93398458457c35d1d0c9bb"

    private fun rejected(operation: () -> Unit) {
        try { operation(); fail("Untrusted transcript was accepted") }
        catch (_: IllegalArgumentException) { }
    }

    @Test fun sharedV2CanonicalTranscriptVector() {
        assertEquals("76e3a88c306079a33eabc893ad297e4a5ef0f8f7f84297561ce2893c590d382f",
            ComputerTrust.clientCommitment(fingerprint, clientSecret))
        assertEquals(commitment, ComputerTrust.serverCommitment(fingerprint, requestId, claimSecret, serverSecret))
        assertEquals("558025", ComputerTrust.verificationCode(fingerprint, requestId, clientSecret, serverSecret))
        val captured = ComputerTrust.ServerCommitment(fingerprint, requestId, claimSecret, commitment)
        assertEquals("558025", captured.verifiedCode(clientSecret, serverSecret, "558025"))
    }

    @Test fun changedRevealCannotReplaceCommittedServerSecretEvenWithMatchingNewCode() {
        val captured = ComputerTrust.ServerCommitment(fingerprint, requestId, claimSecret, commitment)
        val changedSecret = "78".repeat(32)
        val changedCode = ComputerTrust.verificationCode(fingerprint, requestId, clientSecret, changedSecret)
        rejected { captured.verifiedCode(clientSecret, changedSecret, changedCode) }
        // A failed reveal cannot mutate the original captured tuple.
        assertEquals("558025", captured.verifiedCode(clientSecret, serverSecret, "558025"))
    }

    @Test fun capturedCommitmentRejectsRebindingOfEveryServerField() {
        val otherId = "d3f39110-349d-4c92-a49e-977891949688"
        rejected {
            ComputerTrust.ServerCommitment("cd".repeat(32), requestId, claimSecret, commitment)
                .verifiedCode(clientSecret, serverSecret, ComputerTrust.verificationCode("cd".repeat(32), requestId, clientSecret, serverSecret))
        }
        rejected {
            ComputerTrust.ServerCommitment(fingerprint, otherId, claimSecret, commitment)
                .verifiedCode(clientSecret, serverSecret, ComputerTrust.verificationCode(fingerprint, otherId, clientSecret, serverSecret))
        }
        rejected {
            ComputerTrust.ServerCommitment(fingerprint, requestId, "78".repeat(32), commitment)
                .verifiedCode(clientSecret, serverSecret, "558025")
        }
    }

    @Test fun invalidOrOldTranscriptFieldsNeverReachCanonicalEncoding() {
        rejected { ComputerTrust.clientCommitment(fingerprint.uppercase(), clientSecret) }
        rejected { ComputerTrust.clientCommitment(fingerprint, "old_client_nonce_1234") }
        rejected { ComputerTrust.clientCommitment(fingerprint, "12\"], [\"injection") }
        rejected { ComputerTrust.ServerCommitment(fingerprint, "1-1-1-1-1", claimSecret, commitment) }
        rejected { ComputerTrust.ServerCommitment(fingerprint, requestId.uppercase(), claimSecret, commitment) }
        rejected { ComputerTrust.ServerCommitment(fingerprint, requestId, claimSecret, "00") }
        rejected { ComputerTrust.serverCommitment(fingerprint, requestId, claimSecret, "AB".repeat(32)) }
    }

    @Test fun onlyLocallyDerivedExactSixDigitCodeIsAccepted() {
        val captured = ComputerTrust.ServerCommitment(fingerprint, requestId, claimSecret, commitment)
        rejected { captured.verifiedCode(clientSecret, serverSecret, "000000") }
        rejected { captured.verifiedCode(clientSecret, serverSecret, "558025 ") }
        rejected { captured.verifiedCode(clientSecret, serverSecret, "0558025") }
        rejected { captured.verifiedCode("78".repeat(32), serverSecret, "558025") }
        assertNotEquals(ComputerTrust.clientCommitment(fingerprint, clientSecret), ComputerTrust.clientCommitment(fingerprint, "78".repeat(32)))
    }
}
