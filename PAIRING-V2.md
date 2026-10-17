# Pairing v2 commit/reveal

Discovery remains an untrusted locator. Phone bootstrap checks the advertised TLS fingerprint and then uses exact certificate pinning. A human compares the six-digit SAS on PC and phone. No automatic approval.

One-round hash binding is insufficient: a rogue TLS endpoint can grind attacker-controlled claim fields offline to match a real PC's code. Replace it with both sides committing before revealing either random secret.

1. Phone chooses clientSecret=64 lowercase hex (32 random bytes). `clientCommitment=SHA256(compact JSON ["omputer-client-v2",pcFingerprint,clientSecret])`.
2. POST `/v1/pair/request` `{name,clientCommitment}`. PC creates immutable requestId UUID, claimSecret=64hex, serverSecret=64hex. `serverCommitment=SHA256(JSON ["omputer-server-v2",pcFingerprint,requestId,claimSecret,serverSecret])`. Return `{version:2,requestId,claimSecret,serverCommitment,expiresAt}`. Store claim hash, client commitment and server secret in bounded expiring queue. No verificationCode returned at this step; UI PC must not approve before reveal.
3. Phone stores server commitment before revealing clientSecret. POST `/v1/pair/reveal` `{requestId,claimSecret,clientSecret}`. PC verifies claim and immutable client commitment. First valid reveal fixes the secret; changed/replayed different secret fails. Return `{version:2,serverSecret,verificationCode}`. Derive `code=first4bytes(SHA256(JSON ["omputer-sas-v2",pcFingerprint,requestId,clientSecret,serverSecret])) mod 1000000`, six zero-padded digits. Code display allowed only after this reveal.
4. Phone verifies serverSecret against previously received serverCommitment then derives and checks the SAS locally. ClaimSecret, both secrets and commitments never go to Dart/notifications/logs; public pairing UI only requestId/code/expires/serverName/fingerprint.
5. PC local admin approval only after valid reveal. Claim POST unchanged requestId/claimSecret; approved consumes once and issues token, pending/denied/expired explicit. A wrong reveal does not mutate the legitimate waiting request. No old v1 clientNonce auto-pair acceptance.
6. Queue two-minute lifetime, five active requests, bounded rate/origin/global. Random client/server secrets regenerated each attempt. mDNS/UDP metadata cannot replace stored credential certificate. SAS remains human/OOB security boundary; mismatched codes must be rejected, no retry-on-mismatch acceptance.

End-to-end tests must cover approve-before-reveal rejected, wrong committed secret rejected but correct reveal succeeds, commit mismatch on client aborts, denied/expired/consumed requests cannot issue tokens, one-use concurrent claim, matching cross-language transcript vector. This is application trust bootstrap, not model prompt content.
