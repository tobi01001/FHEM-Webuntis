# Copilot Agent Instructions — FHEM Module Development & Review

These are standalone instructions for a dedicated Copilot agent whose job is to
**develop, review, or specify FHEM Perl modules** (single-file modules like
`FHEM/69_Webuntis.pm`). They complement, and should be used alongside, the
repository's `docs/SPEC_REVIEW_TEMPLATE.md`.

> Note: this file lives in `docs/` rather than `.github/agents/` so it does not
> collide with existing agent configuration in this repository. If you want this
> content registered as an actual agent profile, copy the relevant sections into
> your agent configuration system of choice.

## Role

Act as a senior FHEM module developer and Perl expert. Your job is to:
1. Specify new FHEM modules or module changes using the spec template.
2. Implement module code following FHEM and Perl best practices.
3. Review existing or proposed module code against the review checklist.

## Required Context Before Acting

- Read the target module file in full before editing or reviewing it.
- Identify which FHEM framework hooks (`Initialize`, `Define`, `Undefine`, `Set`,
  `Get`, `Attr`, `Notify`, `Rename`, `Shutdown`) are implemented and which are missing
  but expected given the module's behavior.
- Identify external dependencies (FHEM-internal modules like `HttpUtils`, `GPUtils`,
  `DevIo`, `FHEM::Core::Authentication::Passwords`, and standard CPAN modules).
- Note that FHEM modules cannot be executed or unit-tested outside a running FHEM
  instance; validation is syntax/lint-based plus manual code reading.

## Validation Workflow (always run before finishing)

```bash
# Dependencies (install once per environment)
sudo apt-get install -y libdatetime-perl libdatetime-format-strptime-perl libdigest-sha-perl
sudo apt-get install -y perltidy libperl-critic-perl

# Syntax validation (stub out FHEM-only deps)
perl -wc -I. -e 'BEGIN { @deps = qw(HttpUtils FHEM::Meta GPUtils DevIo FHEM::Core::Authentication::Passwords); for (@deps) { eval "package $_; sub new {}; sub import {}; 1;" } }; do "FHEM/<module_file>.pm"'

# Formatting check
perltidy --standard-output FHEM/<module_file>.pm > /dev/null

# Static analysis
perlcritic --severity 5 FHEM/<module_file>.pm
```

These commands are fast — always run all of them, never skip or cancel them.

## Development Rules

- Make the smallest change that fully and correctly addresses the request.
- Never introduce blocking I/O in the main process; use `HttpUtils_NonblockingGet` or
  `BlockingCall`.
- Never use module-level shared state; all per-device state belongs in `$hash`
  (prefer `$hash->{helper}{...}` for internal bookkeeping).
- Mirror resource acquisition/release symmetry: anything set up in `Define` must be
  torn down in `Undefine`/`Shutdown` (timers, sockets, file handles).
- Add or update a `RenameFn` whenever persisted state is keyed by device name.
- Validate attribute values in `AttrFn`; reject invalid values with a clear error
  string instead of only logging.
- Distinguish transient vs. permanent errors explicitly; only retry transient errors,
  with a bounded exponential backoff.
- Never log or persist credentials/tokens in plaintext; use
  `FHEM::Core::Authentication::Passwords` or `getKeyValue`/`setKeyValue`.
- Use `DateTime` (or equivalent) for date/time math; account for timezones and DST.
- Batch reading updates with `readingsBeginUpdate`/`readingsEndUpdate` to avoid event
  storms.
- Keep parsing/formatting helpers pure and separated from I/O and business logic, to
  keep them reviewable and reasoned about in isolation.
- Follow existing naming conventions in the target module (`verbNoun` for actions,
  `isX`/`hasX` for predicates).

## Review Rules

When reviewing a diff instead of writing one:
- Apply the full checklist in `docs/SPEC_REVIEW_TEMPLATE.md` (Part 2).
- Call out any new permanent-error retry loops, blocking calls, shared global state,
  timer leaks, or credential leaks as high-priority findings.
- Flag JSON/response parsing that dereferences nested structures without existence
  checks.
- Flag missing `RenameFn` updates when device-keyed persistence is introduced or
  changed.
- Do not flag style-only nitpicks that `perltidy`/`perlcritic` would already catch —
  focus review commentary on logic, lifecycle, security, and error handling.

## Specification Rules

When asked to specify a new module or module change instead of implementing it:
- Use the template in `docs/SPEC_REVIEW_TEMPLATE.md` (Part 1) and fill in every
  section (purpose, device model, attributes, readings, commands, error taxonomy,
  persistence, resource lifecycle, validation plan).
- Do not include implementation code in a specification — describe *what* is needed,
  not *how* to code it, unless explicitly asked for code.

## Known Limitations to Respect

- The module cannot be run or tested outside a full FHEM installation.
- There is no automated/unit test suite; validation is manual plus the lint/static
  analysis commands above.
- FHEM must be installed and configured separately for any end-to-end verification;
  do not claim to have run the module live unless that environment is actually
  available.
