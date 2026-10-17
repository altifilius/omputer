# Omputer protocol v1

UTF-8 JSON; times UTC RFC3339, IDs strings. Phone transport requires HTTPS/WSS with exact certificate pinning. REST/WSS authorization is `Authorization: Bearer <deviceToken>`; tokens never in URLs. Error: HTTP status + `{"error":{"code":"...","message":"..."}}`.

## Pairing and devices

Primary pairing uses untrusted DNS-SD `_omputer._tcp.local.` or bounded same-link UDP discovery (`OMPUTER_DISCOVER_V1`, port 47878). Advertisements carry stable server ID, name, port and fingerprint, never credentials. GET `/v1/identity` exposes only public identity metadata. Strict two-sided v2 commitment/reveal at `/v1/pair/request`, `/v1/pair/reveal`, `/v1/pair/claim` requires matching six-digit codes and local PC approval; canonical transcript, expiry/rate limits and no-v1-fallback rules are specified in `PAIRING-V2.md`. The API path prefix remains `/v1`; pairing transcript version is independently `2`.

Secondary PC-app QR bundle: `{version:1,url:"https://host:port",certificate:"base64 DER",fingerprint:"sha256 lowercase hex",code:"one-use secret",expiresAt:"..."}`. QR encodes `omputer://pair?data=<base64url UTF8 JSON>`. POST `/v1/pair` `{code,name}` -> `{deviceId,token,serverName}`. Ten-minute secret consumed atomically once. GET `/health` -> `{name:"Omputer",protocol:1}` reveals no session content.

Device: `{id,name,createdAt,lastSeenAt?,revokedAt?}`. POST `/v1/devices/:id/revoke` authenticated -> `{success:true}`; ends that device's stream and rejects future requests. Device tokens are hashed on PC and encrypted with Android Keystore on phone.

## Snapshot, continuity, history

GET `/v1/snapshot` -> `{sequence,serverName,projects:[],sessions:[],interactions:[],devices:[]}`.

Project: `{id,name,path,goal,summary,nextStep,decisions:[string],updatedAt,sourceSessionId?,memoryOrigin?:"manual"|"agent",sessionCount,pendingCount,activity?}`. Manual/agent durable checkpoint and automatic live activity are distinct. `activity={sessionId,updatedAt,goal,lastAssistantText,nextStep,todos,pendingCount}` is a truthful projection of normal user input, final assistant answer and earliest active/pending task. A turn ending is never a project completion claim. Source and freshness stay visible; empty fields are valid.

Session: `{id,projectId,name,cwd,transport:"rpc"|"bridge"|"archive",status:"idle"|"running"|"waiting"|"disconnected"|"failed"|"closed"|"active-unbridged",model?:{provider,id,name},thinkingLevel?,updatedAt,sessionFile?,todos:[],subagents:[],capabilities:[string],lastAssistantText?,lastUserMessage?,lastError?,hasPendingAsyncWork?,isSettled?}`. Only actually supported controls are advertised. Automatically imported active uninstrumented sessions are `active-unbridged` with no control/resume capability; inactive archives expose history and safe resume, not live control.

Interaction: `{id,sessionId,projectId,method:"select"|"confirm"|"input"|"editor"|"ask"|"approval",title,message?,options?:[{label,description?}],questions?:[],prefill?,createdAt,expiresAt?,status:"pending"|"resolved"|"cancelled"|"expired"}`. `questions` preserves OMP ask schema. First valid desktop/mobile answer settles; stale/expired second answers are rejected. Authoritative host pending replay preserves request identity/deadline and reconciles disconnected claims.

GET `/v1/sessions/:id/messages?before=<numeric sequence>&limit=50` -> `{messages:[{id,role,content:[],timestamp,sequence,revision}],hasMore}`. OMP text/thinking/toolCall/toolResult blocks kept. Stable page ordering; accumulating message updates replace by ID. `sequence` is the chronological paging position; `revision` increases on replacements at that position, so an older HTTP page cannot overwrite newer live text. Native OMP transport negotiates lossless RPC v2 chunks and pages idle history. `session.event:{type:"transcript_reset"}` retires a changed branch before replacement upserts.

GET `/v1/projects/:id/files?path=<relative>` -> `{path,text,truncated}`. Read-only bounded UTF-8, atomically confined beneath canonical registered root; escaping symlinks rejected.

GET `/v1/models` -> `{models:[{provider,id,name}]}` from OMP, no credentials/system prompts/provider transport internals.
PATCH `/v1/projects/:id` `{goal?,summary?,nextStep?,decisions?,sourceSessionId?}` -> Project. Explicit manual edits are distinct from automatic activity.

## Acknowledged commands

POST `/v1/commands` `{id:<UUID>,sessionId?,action,payload:{...}}` -> `{id,success:true,data?}` or structured failure. UUIDs deduplicated persistently; unknown outcome is not silently repeated.

- `session.start`: `{projectId,name?,model?:{provider,id},prompt?}`.
- `session.resume`: `{sessionId}`; refuses an existing runtime ownership lease.
- `session.prompt`, `session.steer`, `session.follow_up`: `{message,images?:[]}`.
- `session.abort`: `{}`; does not claim every descendant system process stopped.
- `session.model`: `{provider,modelId}`; `session.thinking`: `{level}`.
- `session.compact`: `{instructions?}`; `session.rename`: `{name}`; `session.refresh`: `{}`.
- `session.bash`: `{command}` explicit command, not terminal keystroke injection.
- `agent.command`: `{agentId,command:"chat"|"kill"|"revive",message?}` actual OMP lifecycle operations.
- `interaction.respond`: `{interactionId,value?:string,confirmed?:boolean,cancelled?:boolean,answer?:object}`. Ask answer: `{kind:"submit",results:[{id,question?,options?:[string],multi?:boolean,selectedOptions:[string],customInput?,note?}]}`; canonical host fills/validates question facts. Approval uses `confirmed`. Full request validation precedes claim.

## Event stream

WSS `/v1/events?after=<sequence>` with authenticated handshake. Journal envelope `{sequence,type,sessionId?,projectId?,data,createdAt}`. Types: `snapshot`, `session.updated`, `session.event`, `message.upsert`, `interaction.pending`, `interaction.resolved`, `project.updated`, `notification`, `device.revoked`. Replay then caught-up snapshot at same watermark, then live events. Ping/pong liveness; revoked device gets explicit terminal state. Android accepts equal-watermark authoritative snapshot. Snapshot and cursor are tied to pairing identity; re-pair clears previous server content.

Notification: `{id,kind:"question"|"approval"|"turn_done"|"error"|"connection",title,body,sessionId?,interactionId?}`. Generated locally on Android; no push provider. Approval opens detail, no blind lock-screen permission action.

## Local OMP bridge

Mode-0600 Unix socket `<stateDir>/bridge.sock`; mode-0600 secret `<stateDir>/bridge.token`; owner-only state directory. Register JSONL `{type:"register",token,managed?:bool,managedSessionId?,session:{id,cwd,name,sessionFile?,model?,thinkingLevel?,status,todos,subagents,capabilities}}` -> `{type:"registered",sessionId,projectId}`. Managed IPC owns dialogs/subagent/checkpoints; native RPC owns session commands/transcript. Terminal IPC owns both. No hosted Collab relay.

Bridge -> daemon: `{type:"event",sessionId,event}`, `{type:"state",session}`, `{type:"interaction",sessionId,request}`, `{type:"interaction_end",sessionId,id,status}`, `{type:"response",id,success,data?,error?}`.
Daemon -> bridge: `{type:"command",id,action,payload}`.
Checkpoint: `{type:"checkpoint",id,sessionId,data:{goal,summary,nextStep,decisions:[string]}}` -> correlated `{type:"response",id,success,data?,error?}` after local persistence. Essential `omputer_checkpoint` tool reports success only after acknowledgement; guidance adds no model request. IPC reconnect alone never answers a host dialog; authoritative pending replay preserves stable identity.
