# FHEM Webuntis Module


# FHEM-Webuntis Copilot Instructions

FHEM-Webuntis is a single-file Perl module for the FHEM home automation system, integrating with Webuntis school cloud services. All logic is in `FHEM/69_Webuntis.pm` and requires the FHEM framework and specific FHEM modules.

## Architecture & Structure
- **Single main module:** All code in `FHEM/69_Webuntis.pm`.
- **FHEM integration:** Relies on FHEM-specific modules (`HttpUtils`, `GPUtils`, etc.) not available in standard Perl environments.
- **No build system or unit tests:** Validation is manual and via Perl tools.

## Critical Developer Workflows
- **Install dependencies:**
  ```bash
  sudo apt-get install -y libdatetime-perl libdatetime-format-strptime-perl libdigest-sha-perl
  sudo apt-get install -y perltidy libperl-critic-perl
  ```
- **Syntax validation:**
  ```bash
  perl -wc -I. -e 'BEGIN { @deps = qw(HttpUtils FHEM::Meta GPUtils DevIo FHEM::Core::Authentication::Passwords); for (@deps) { eval "package $_; sub new {}; sub import {}; 1;" } }; do "FHEM/69_Webuntis.pm"'
  ```
- **Formatting:**
  ```bash
  perltidy --standard-output FHEM/69_Webuntis.pm > /dev/null
  ```
- **Static analysis:**
  ```bash
  perlcritic --severity 5 FHEM/69_Webuntis.pm
  ```
**Always run all validation steps before committing. Never cancel these commands—they are fast.**

## Project-Specific Patterns
- **Retry logic:** Network errors are retried with exponential backoff. Configurable via `maxRetries` and `retryDelay` attributes.
- **Error handling:** Transient errors (timeouts, server errors, malformed JSON) are retried; permanent errors (auth, config) are not.
- **Manual review required:** Especially for changes to HTTP requests, JSON parsing, and date/time logic.

## Key Functions & Areas
- `Initialize`, `Define`, `Undefine`, `Set`, `Get`: FHEM lifecycle and command interface.
- `login`, `getTimeTable`, `parseTT`: Webuntis API and data handling.
- **Critical code regions:**
  - HTTP requests: lines ~540, 632, 728
  - JSON parsing: `parseLogin`, `parseClass`, `parseTT`
  - Date/time: lines ~640-680
  - iCal export: `exportTT2iCal`

## Integration Points
- **External dependencies:**
  - FHEM modules (not installable via CPAN)
  - Standard Perl modules: `DateTime`, `Digest::SHA`, `JSON`, etc.
- **Outputs:**
  - iCal files (path via `iCalPath` attribute)
  - Log entries (FHEM's `Log3`)
  - Device readings

## Limitations
- Cannot run or test module outside FHEM.
- No automated/unit tests.
- FHEM must be installed and configured separately.

## Validation Checklist
- [ ] Syntax validation
- [ ] Code formatting (perltidy)
- [ ] Static analysis (perlcritic)
- [ ] Manual review of changed functions
- [ ] Test new date/time logic with edge cases
- [ ] Verify JSON parsing for malformed data
- [ ] Check HTTP error handling

---

For questions or unclear areas, review the README or ask for clarification. Update this file if new patterns or workflows emerge.