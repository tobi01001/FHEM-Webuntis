# FHEM Webuntis Module

FHEM-Webuntis is a Perl module for the FHEM home automation system that retrieves timetable information from Webuntis school cloud services. This is a single-file Perl module that integrates with the FHEM framework.

Always reference these instructions first and fallback to search or bash commands only when you encounter unexpected information that does not match the info here.

## Working Effectively

The repository contains a single FHEM module (`69_Webuntis.pm`) and does not have a traditional build system. However, you can validate and work with the code using the following commands:

### Environment Setup and Dependencies
- Install required Perl modules: `sudo apt-get install -y libdatetime-perl libdatetime-format-strptime-perl libdigest-sha-perl` -- takes 5-10 seconds. NEVER CANCEL.
- Install code quality tools: `sudo apt-get install -y perltidy libperl-critic-perl` -- takes 30-60 seconds. NEVER CANCEL.
- Basic Perl is available at `/usr/bin/perl` (version 5.38.2)

### Code Validation (CRITICAL - Always run before committing)
- **Syntax validation**: `perl -wc -I. -e 'BEGIN { @deps = qw(HttpUtils FHEM::Meta GPUtils DevIo FHEM::Core::Authentication::Passwords); for (@deps) { eval "package $_; sub new {}; sub import {}; 1;" } }; do "FHEM/69_Webuntis.pm"'` -- takes <1 second
- **Code formatting check**: `perltidy --standard-output FHEM/69_Webuntis.pm > /dev/null` -- takes 1 second
- **Static analysis**: `perlcritic --severity 5 FHEM/69_Webuntis.pm` -- takes 1 second

### Testing and Validation Scenarios
Since this module requires the FHEM framework to function properly, full functional testing is not possible in a standard environment. However, you MUST validate the following:

- **ALWAYS run syntax validation** after any code changes
- **ALWAYS run code formatting checks** to ensure style consistency
- **ALWAYS run static analysis** to catch potential issues
- **Manual code review** of any changes to HTTP requests, JSON parsing, or date/time handling

## Repository Structure
```
FHEM-Webuntis/
├── .git/                    # Git repository data
├── .gitignore              # Git ignore patterns
├── FHEM/                   # FHEM module directory
│   └── 69_Webuntis.pm     # Main Perl module (single file)
├── LICENSE                 # MIT license
└── README.md              # Basic project description
```

## Cannot Do / Limitations
- **Cannot run the module directly**: Requires full FHEM installation with dependencies like HttpUtils, DevIo, FHEM::Meta
- **Cannot perform functional testing**: Module needs FHEM framework and Webuntis server access
- **Cannot install FHEM easily**: FHEM is not available via standard package managers
- **No unit tests exist**: Repository contains no test files

## Common Development Tasks

### Syntax Checking (ESSENTIAL)
Always run before committing changes:
```bash
perl -wc -I. -e 'BEGIN { 
  @deps = qw(HttpUtils FHEM::Meta GPUtils DevIo FHEM::Core::Authentication::Passwords);
  for (@deps) { eval "package $_; sub new {}; sub import {}; 1;" }
}; 
do "FHEM/69_Webuntis.pm"'
```

### Code Quality Checks
Run both formatting and analysis:
```bash
perltidy --standard-output FHEM/69_Webuntis.pm > /dev/null
perlcritic --severity 5 FHEM/69_Webuntis.pm
```

### File Structure Validation
```bash
ls -la FHEM/
file FHEM/69_Webuntis.pm  # Should show: Perl5 module source, ASCII text
```

## Module-Specific Information

### Key Functions
- `Initialize()`: Module initialization for FHEM
- `Define()`, `Undefine()`: Device lifecycle management  
- `Set()`, `Get()`: FHEM command interface
- `login()`: Webuntis API authentication
- `getTimeTable()`: Retrieve timetable data
- `parseTT()`: Parse and process timetable responses

### Dependencies (Not Available in Standard Environment)
- `HttpUtils`: FHEM HTTP utilities
- `FHEM::Meta`: FHEM metadata handling
- `GPUtils`: FHEM general purpose utilities
- `DevIo`: FHEM device I/O
- `FHEM::Core::Authentication::Passwords`: Password management

### External Dependencies (Available)
- `DateTime`: Date/time manipulation
- `Digest::SHA`: Cryptographic hashing
- `JSON` (various implementations): JSON encoding/decoding
- Standard Perl modules: `Data::Dumper`, `List::Util`, `POSIX`, etc.

## Important Code Areas

When making changes, pay special attention to:
- **HTTP requests** (lines around 540, 632, 728): Authentication and API calls
- **JSON parsing** (parseLogin, parseClass, parseTT functions): Data handling
- **Date/time calculations** (lines 640-680): Timetable date ranges
- **iCal export** (exportTT2iCal function): File output functionality

## Validation Checklist
Before committing any changes:
- [ ] Run syntax validation - MUST pass
- [ ] Run perltidy formatting check - MUST pass
- [ ] Run perlcritic analysis - Review warnings
- [ ] Manual review of changed functions
- [ ] Test any new date/time logic with edge cases
- [ ] Verify JSON parsing handles malformed data
- [ ] Check that HTTP error handling is robust

## Common File Outputs
- iCal files: Written to path specified in `iCalPath` attribute
- Log entries: Via FHEM's Log3 function (levels 0-5)
- Readings: FHEM device state information

## Time Expectations
- Dependency installation: 30-60 seconds total
- Syntax validation: <1 second
- Code formatting check: 1 second  
- Static analysis: 1 second
- All validation steps combined: <5 seconds

NEVER CANCEL any validation commands - they complete quickly.