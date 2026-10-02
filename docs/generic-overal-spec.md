
## Greenfield Specification (Part 1, per `docs/SPEC_REVIEW_TEMPLATE.md`)

This is a **two-module** design: one physical module owns the server connection and request pacing; one logical module owns one account's timetable/change-tracking/export behavior.

### Module A: `WebuntisServer` (physical / IODev)

**1. Purpose & External Integration**
- Integrates with exactly one Webuntis school-cloud *backend* (one `server` + `school` pair — some installations host multiple schools behind the same hostname, and the rate limit may apply at either granularity, so this must be a configurable key, not an assumption).
- Does not itself represent a user/timetable; its sole job is connection management: request queueing, pacing, retry/backoff policy, and (optionally) shared session reuse.
- Protocol: HTTPS JSON-RPC, strictly non-blocking.
- Rate limits/quotas: unpublished and must be treated as a hard, conservative floor rather than a best guess. This module is the single enforcement point.

**2. Device Model**
- One `define` instance = one server+school combination (or one server if rate limiting is host-wide; configurable).
- Multiple `WebuntisAccount` logical devices attach to it via `IODev` (standard FHEM `AssignIoPort` mechanism).
- No global/module-level state: the queue, in-flight flag, and per-child bookkeeping live in `$hash->{helper}` of the `WebuntisServer` instance, keyed by child device name.

**3. Attributes**
| Name | Type | Default | Validation | Runtime-changeable |
|---|---|---|---|---|
| `rateLimitScope` | enum `host`,`host+school` | `host+school` | fixed set | yes |
| `minRequestInterval` | int (seconds) | e.g. 3 | hard floor, reject below a minimum safe value (not just documented as convention) | yes |
| `maxConcurrentRequests` | int | 1 | range 1–2 (never unbounded) | yes |
| `maxRetries` / `retryDelay` | int | defaults | as today's error-handling pattern | yes |
| `queueFairness` | enum `fifo`,`roundRobin` | `roundRobin` | fixed set | yes |
| `disable` | yes/no | no | — | yes |

**4. Readings**
- `queueLength`, `lastDispatch`, `state` (`idle`/`throttled`/`error`), per-backend error counters — enough to make throttling observable without exposing any one child's business data.

**5. Set/Get**
- `get queueStatus` — introspection for debugging shared-queue contention.
- No "timetable" semantics live here at all — this module never parses Webuntis business data, only transports it.

**6. Error Taxonomy**
- Transient (timeout, 5xx, connection reset): retried per backoff policy, *at the server level*, so a single backoff affects queue pacing for all children fairly rather than each child independently hammering retries.
- Permanent (401/403 on a specific child's session): surfaced back to the originating `WebuntisAccount` only — must not stall or poison the shared queue for other children (`queueFairness=roundRobin` exists specifically to guarantee this isolation).
- A new category unique to this module: **queue starvation / backend-wide lockout** (repeated failures across *all* children, not just one) — distinguished explicitly, since that implies the whole backend is blocking the module, not just one bad credential.

**7. Persistence**
- Nothing account-specific; only aggregate counters, which can be transient (non-persisted) or reading-based.

**8. Resource Lifecycle**
- `Define` creates the queue/timer infrastructure.
- `Undefine`/`Shutdown`: must refuse to undefine while logical devices still reference it (or explicitly detach them with a warning), drain/cancel the queue, remove timers.
- `RenameFn`: update is mostly handled by FHEM's own `IODev` attribute resolution, but the module must verify reattachment on rename rather than assume it.

### Module B: `WebuntisAccount` (logical device)

**1. Purpose & External Integration**
- Represents exactly one Webuntis login (one student, one class, or one teacher view). All network I/O is delegated to its `IODev` (a `WebuntisServer`); this module never opens an HTTP connection directly.
- Authentication: user/password, submitted through the IODev's queue; credentials stored via `FHEM::Core::Authentication::Passwords`, scoped to this child device.

**2. Device Model**
- One `define` = one account. Must declare/require an `IODev` (either explicit attribute or auto-match by `server`+`school` against existing `WebuntisServer` instances, same convention as other FHEM physical/logical pairs).
- Many `WebuntisAccount` instances can share one `WebuntisServer`.

**3. Attributes**
- `IODev`, `studentID`/`classID`/`teacherID`, `timeTableMode`, `daysAhead`, `daysBehind`, `schoolYearStart/End`.
- Change-detection: `changeDetectionMode` (`snapshotDiff` as the only well-defined mode — diffing a persisted previous full timetable, keyed by lesson id, against the newly fetched one), `changeRetentionDays`, exception/noise filters (`excludeSubjects`, filter expressions) applied *after* diffing.
- Export: `iCalPath`, `iCalMode` (`fullTimetable`/`changesOnly`/`both`), `publishHttp` (serve via a `GetFn` instead of/alongside a file).

**4. Readings**
- Current-state family: `state`, `timetable`, `lastUpdate`.
- Change family: `changeCount`, `changeToday`, `changeTomorrow`, stable content-keyed per-change readings (not positional indices), `lastChangeTimestamp`/`lastChangeSummary` — updated only on genuine change (`readingsBulkUpdateIfChanged`), to avoid event storms independent of poll frequency.

**5. Set/Get**
- `set password`, `set update` (enqueue an immediate fetch job on the IODev), `set clearChanges`.
- `get timetable [range]`, `get changes [since]`, `get ical`.

**6. Error Taxonomy**
- Same transient/permanent split, but errors arrive *from* the IODev's dispatch callback, not from a direct HTTP call — the account module reacts to (success | transient-will-retry | permanent-fail) events emitted by the server module, rather than owning retry/backoff itself. This cleanly separates "pacing/connection" concerns (server) from "business logic" concerns (account).

**7. Persistence**
- Last-known full timetable snapshot (keyed by lesson id/date/period) must persist across restarts so change detection doesn't falsely report a full "everything changed" or "nothing changed" on reboot.
- Session/credentials via `FHEM::Core::Authentication::Passwords`.

**8. Resource Lifecycle**
- `Define` registers with its `IODev`; `Undefine` deregisters from the `IODev`'s queue and cleans up any temp files from iCal export.
- `RenameFn` required (snapshot/password persistence keyed by device name).

**9. Validation Plan (both modules)**
- Standard syntax/perltidy/perlcritic validation.
- Multi-device test scenarios specific to the IODev design: two `WebuntisAccount`s on one `WebuntisServer` firing `set update` simultaneously (must serialize, never produce two concurrent HTTP calls), one account's permanent auth failure (must not block the other account's polling), `WebuntisServer` `Undefine` attempted while children are still attached (must be rejected or must cleanly detach), queue behavior under sustained transient failure (global backoff must slow *all* children proportionally, not multiply retries per child).
