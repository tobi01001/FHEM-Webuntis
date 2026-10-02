# FHEM Module Specification & Review Template

This document provides a reusable specification template and review checklist for
developing and reviewing FHEM Perl modules (such as `FHEM/69_Webuntis.pm`). Hand this
out to anyone who needs to **specify**, **develop**, or **review** an FHEM module.

---

## Part 1 — Specification Template

Use this template to define a new module (or a significant change to an existing one)
before writing code.

### 1. Purpose & External Integration
- What external system/API/service does the module integrate with?
- Authentication method (token, user/password, OAuth, none)?
- Rate limits / quotas imposed by the external service?
- Protocol (HTTP/HTTPS, local socket, serial, MQTT, ...)?

### 2. Device Model
- What does **one** `define` instance represent (one account? one sensor? one calendar)?
- Can multiple instances coexist without shared/global state conflicts?
- Is there a parent/child (`IODev`) relationship with another module?

### 3. Attributes
For each attribute, specify:

| Name | Type | Default | Validation rule | Runtime-changeable? |
|------|------|---------|------------------|----------------------|
| example | enum/int/string | ... | regex / range | yes/no |

### 4. Readings
For each reading, specify:

| Name | Meaning | Update trigger/frequency | Event generation (all/on-change) |
|------|---------|---------------------------|------------------------------------|

### 5. Set / Get Commands
For each command, specify:
- Signature (arguments, types, optional/required)
- Side effects (readings changed, external calls triggered)
- Synchronous or asynchronous execution
- Error behavior on invalid arguments

### 6. Error Taxonomy
- List **transient** errors (timeouts, 5xx responses, malformed JSON) and required
  handling (retry with backoff).
- List **permanent** errors (bad credentials, invalid config) and required handling
  (fail fast, surface clear error reading/log, no retry loop).
- Define `maxRetries` / `retryDelay` (or equivalent) attributes and defaults.

### 7. Persistence
- What state must survive a FHEM restart (tokens, last-sync timestamp, cached data)?
- How is it persisted (`setKeyValue`/`getKeyValue`, `FHEM::Core::Authentication::Passwords`,
  readings, files)?
- Are secrets stored encrypted and excluded from `DEF`, logs, and `list` output?

### 8. Resource Lifecycle
- What is created in `Define` (timers, sockets, `DevIo` handles, temp files)?
- What must be torn down in `Undefine`/`Shutdown`?
- Is a `RenameFn` required (i.e., is persisted state keyed by device name)?

### 9. Validation Plan
- Syntax check command.
- `perltidy` formatting check.
- `perlcritic` severity threshold.
- Manual test scenarios, including:
  - Edge-case date/time inputs (DST transitions, year boundaries, timezones).
  - Malformed/partial/empty API responses.
  - Network failure and recovery (timeout, 5xx, connection refused).

---

## Part 2 — Review Checklist

Use this checklist when reviewing a pull request that adds or modifies an FHEM module.

### A. FHEM Lifecycle Correctness
- [ ] `Initialize` registers all used `Fn` hooks (`DefFn`, `UndefFn`, `SetFn`, `GetFn`,
      `AttrFn`, `NotifyFn`, `RenameFn`, `ShutdownFn` as applicable).
- [ ] Every resource acquired in `Define` (timers via `InternalTimer`, sockets, `DevIo`
      handles, temp files) is released in `Undefine`/`Shutdown`.
- [ ] `RemoveInternalTimer($hash)` is called on `Undefine`/`Shutdown` to avoid orphaned
      timers.
- [ ] If persisted state is keyed by device name, a `RenameFn` migrates it correctly.
- [ ] Attribute values are validated in `AttrFn` *before* being applied; invalid values
      return an error string rather than just logging.
- [ ] `$init_done` is checked where needed to avoid premature action during config load.

### B. Concurrency & Blocking
- [ ] No blocking network/file I/O in the main process — HTTP goes through
      `HttpUtils_NonblockingGet` (or `BlockingCall` for unavoidable blocking work).
- [ ] No module-level `my` variables holding per-device state shared across instances;
      all instance state lives in `$hash` (e.g. `$hash->{helper}{...}`).
- [ ] Callback closures capture `$hash`/device identity correctly and don't leak state
      between devices.

### C. Perl Quality
- [ ] `use strict; use warnings;` present.
- [ ] `perlcritic --severity 5` clean (or justified exceptions documented).
- [ ] `perltidy --standard-output` produces no unexpected diff (formatting consistent).
- [ ] JSON parsing wrapped in `eval`/a safe-decode helper; `ref($data) eq 'HASH'/'ARRAY'`
      checked before dereferencing; missing keys handled with `exists`/`//` defaults.
- [ ] No silent catch-all `eval` that swallows errors without logging via `Log3`.

### D. Error Handling & Retry Logic
- [ ] Transient vs. permanent errors are explicitly distinguished.
- [ ] Retries use exponential backoff with a configurable cap (`maxRetries`,
      `retryDelay` or equivalent attributes).
- [ ] Permanent errors (e.g., authentication failure) are **not** retried indefinitely.
- [ ] Failures are surfaced to the user via a reading/state and `Log3`, not just silently
      dropped.

### E. Security
- [ ] Credentials go through `FHEM::Core::Authentication::Passwords` (or
      `getKeyValue`/`setKeyValue`), never stored in plaintext attributes.
- [ ] Secrets/tokens are never written to `Log3` output or exposed via `list`.
- [ ] No new external dependency introduces an unreviewed security risk (prefer core/
      well-known CPAN modules already used by other FHEM modules).

### F. Date/Time Handling
- [ ] Date/time math uses `DateTime` (or equivalent) rather than naive string arithmetic.
- [ ] Timezone and DST transitions are considered for any date/time comparison or
      formatting.

### G. Object/Structural Conventions
- [ ] Internal bookkeeping state lives under `$hash->{helper}{...}`, not loose top-level
      keys, unless it's a documented Internal.
- [ ] Parsing/formatting helper functions are pure (no side effects, explicit args) and
      separated from I/O and business-logic subs.
- [ ] Naming follows `verbNoun` for actions (`getTimeTable`) and `isX`/`hasX` for
      predicates (`isAuthenticationError`).
- [ ] Multi-step async flows (login → fetch → parse) use an explicit queue/state machine
      rather than deeply nested callbacks.

### H. Readings & Events
- [ ] Multiple reading updates are batched with `readingsBeginUpdate`/
      `readingsEndUpdate` to avoid event storms.
- [ ] Reading names and semantics match what was specified (Part 1, Section 4).

### I. Documentation
- [ ] Module changes are reflected in README/USAGE docs where user-facing behavior
      changed.
- [ ] `FHEM::Meta` / version metadata updated if present.

---

## Common Pitfalls (Quick Reference)

- Timer/resource leak on `Undefine` (orphaned `InternalTimer`).
- Blocking network/file I/O in the main process.
- Shared mutable state across device instances.
- Unvalidated/untrusted JSON structure dereferenced directly.
- Silent catch-all `eval` swallowing real errors without `Log3`.
- Retry logic without a backoff cap, causing log/API flooding.
- Permanent errors (bad credentials) retried indefinitely.
- Secrets leaked via logs, `DEF`, or plain attributes.
- Date/time math ignoring timezone/DST.
- Missing `RenameFn` when device-keyed persistent data exists.
- Missing attribute validation, causing crashes on bad user input.
- Readings set without batching, causing event storms.
- File output (e.g., iCal export) without path/permission validation or atomic write.
