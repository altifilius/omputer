# Android / Flutter boundary

Flutter uses `MethodChannel('omputer/connection')` and `EventChannel('omputer/events')`. Native Kotlin owns HTTPS/WSS transport, exact DER certificate pinning, encrypted device credentials, foreground/background connection, cached snapshot, sequence cursor and Android notifications. No Dart network calls on Android; no duplicate sockets. UI remains usable with cached data.

Methods:
- `discover` args `{enabled:bool}` -> `{scanning,error?}`. Native DNS-SD and bounded local broadcast discovery publish untrusted candidates, never credentials.
- `pairRequest` args `{computerId,name,background:bool}` -> `{requestId,verificationCode,expiresAt,serverName,fingerprint}`. Native completes strict `PAIRING-V2.md` commit/reveal, captures the server commitment before client reveal, validates the opening and derives the code locally. No pairing secrets or commitments cross into Flutter.
- `pairPoll` -> `{status:'pending'|'approved'|'denied'|'expired'}`; only approval installs credentials and clears the previous server cache atomically. Cancellation/revision guards reject stale network results.
- `pairCancel` -> clears local pending state and cancels tracked calls; no silent pairing. The PC request expires without approval.
- `pair` args `{bundle:<QR payload or omputer://pair URI>,name:<device label>}` -> `{deviceId,serverName,url}`. Secondary camera/deep-link recovery only; native validates the exact certificate and consumes the ten-minute one-use bundle. Primary onboarding is nearby-PC selection and matching-code approval, not JSON paste.
- `connection` no args -> `{paired:bool,connected:bool,background:bool,notifications:bool,batteryExempt:bool,serverName?:string,url?:string,lastError?:string}`.
- `snapshot` -> last cached PROTOCOL snapshot or `{sequence:0,serverName:'',projects:[],sessions:[],interactions:[],devices:[]}`.
- `request` args `{method:'GET'|'POST'|'PATCH',path:'/v1/...',body?:object}` -> parsed JSON. Errors are PlatformException with code from API and human message. Paths must be relative `/v1/`; no arbitrary remote URL.
- `connect` -> connection map; foreground-only connection allowed before background permission granted.
- `background` args `{enabled:bool}` -> connection map. User chooses ongoing visible connected-device service. Do not promise delivery after Android force-stop.
- `notifications` -> request POST_NOTIFICATIONS permission, return bool.
- `batterySettings` -> opens OS battery-optimization page, no blanket permissions silently.
- `forget` -> deletes local pairing and cache, stops service. Server revocation is separate.
- `theme` args `{mode:'system'|'dark'|'light'}` -> persists local preference.
- `preferences` -> `{theme:'system'|'dark'|'light'}`.

Event channel envelopes:
- `{type:'discovery',data:{computers:[{id,name,url,fingerprint}],scanning,error?}}`. Existing-server rediscovery may change only URL after proving the original server ID and exact stored certificate; an independent bounded probe worker does not block interactive requests.
- `{type:'connection',data:<connection map>}`.
- `{type:'snapshot',data:<snapshot>}` after initial refresh and relevant state changes.
- `{type:'event',data:<PROTOCOL journal event>}`. UI applies message upserts to open conversation and refreshes snapshot state as needed.
- `{type:'navigate',data:{sessionId?,interactionId?,bundle?}}` from notification tap or `omputer://pair` deep link. Handle pending intent on startup as well.

Flutter files owned by UI implementation: `mobile/lib/**`, `mobile/pubspec.yaml`, `mobile/test/**` only. Parent owns Android platform files and final integration. App name Omputer; Turkish interface; read PRODUCT.md, PLAN.md, PROTOCOL.md and `.impeccable/surface-briefs/android.md`. Do not add synthetic default data. Local UI may show meaningful empty states. Flutter widget tests may inject a controller for deterministic state but production must use the native adapter.
