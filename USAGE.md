# FHEM Webuntis Module - Usage Guide

## Overview

The `69_Webuntis.pm` module retrieves timetable data from the Webuntis school cloud service for use in the FHEM home automation system.

## Requirements

### Required Perl Modules

The following Perl modules must be installed:

```bash
# On Debian/Ubuntu:
sudo apt-get install -y libdatetime-perl libdatetime-format-strptime-perl libdigest-sha-perl

# On other systems, use CPAN:
cpan DateTime DateTime::Format::Strptime Digest::SHA
```

Additionally, one of these JSON modules is required:
- `JSON::XS` (recommended for performance)
- `JSON::PP` (pure Perl fallback)
- `Cpanel::JSON::XS`
- `JSON::MaybeXS`

### FHEM-Specific Dependencies

The module requires these FHEM internal modules (automatically available in FHEM):
- `HttpUtils`
- `FHEM::Meta`
- `GPUtils`
- `DevIo`
- `FHEM::Core::Authentication::Passwords`

## Installation

1. Copy `FHEM/69_Webuntis.pm` to your FHEM modules directory (typically `/opt/fhem/FHEM/`)
2. Restart FHEM or reload the module

## Basic Setup

### Step 1: Define the Device

```
define myWebuntis Webuntis
```

### Step 2: Set Required Attributes

```
attr myWebuntis server https://your-school.webuntis.com
attr myWebuntis school your_school_name
attr myWebuntis user your_username
attr myWebuntis class 5a
```

### Step 3: Set Your Password

```
set myWebuntis password your_secret_password
```

## Available Commands

### Get Commands

| Command | Description |
|---------|-------------|
| `get myWebuntis timetable` | Retrieve timetable data from Webuntis |
| `get myWebuntis classes` | Display available classes (cached) |
| `get myWebuntis retrieveClasses` | Fetch classes from server |
| `get myWebuntis schoolYear` | Retrieve school year boundaries |
| `get myWebuntis passwordStatus` | Check password validation status |
| `get myWebuntis getJSONtimeTable` | Get raw JSON timetable data |
| `get myWebuntis getSimpleTable` | Get formatted exception table |

### Set Commands

| Command | Description |
|---------|-------------|
| `set myWebuntis password <password>` | Set/update your Webuntis password |

## Attributes

### Required Attributes

| Attribute | Description | Example |
|-----------|-------------|---------|
| `server` | Webuntis server URL | `https://server.webuntis.com` |
| `school` | Your school identifier | `myschool` |
| `user` | Your Webuntis username | `student123` |
| `class` | Class to retrieve timetable for | `5a` |

### Optional Attributes

| Attribute | Description | Default |
|-----------|-------------|---------|
| `interval` | Polling interval in seconds (min 300) | `3600` |
| `DaysTimetable` | Number of days to retrieve | `7` |
| `startDayTimeTable` | Start day for timetable | `Today` |
| `disable` | Disable the module (0/1) | `0` |

### Student-Specific Attributes

| Attribute | Description |
|-----------|-------------|
| `studentID` | Student ID for individual timetables |
| `timeTableMode` | `class` or `student` mode |

### Exception Handling Attributes

| Attribute | Description |
|-----------|-------------|
| `exceptionIndicator` | Fields that indicate exceptions |
| `exceptionFilter` | Filter out specific exception values |
| `excludeSubjects` | Subjects to ignore |
| `considerTimeOfDay` | Only show future exceptions (`yes`/`no`) |

### School Year Attributes

| Attribute | Format | Description |
|-----------|--------|-------------|
| `schoolYearStart` | `YYYY-MM-DD` | Start of school year |
| `schoolYearEnd` | `YYYY-MM-DD` | End of school year |

### iCal Export Attributes

| Attribute | Description |
|-----------|-------------|
| `iCalPath` | Directory path for iCal export (must exist and be writable) |

### Retry Configuration

| Attribute | Range | Default | Description |
|-----------|-------|---------|-------------|
| `maxRetries` | 0-10 | 3 | Max retry attempts |
| `retryDelay` | 5-300 | 30 | Initial retry delay (seconds) |

## Example Configurations

### Basic Student Timetable

```
define myWebuntis Webuntis
attr myWebuntis server https://myschool.webuntis.com
attr myWebuntis school myschool
attr myWebuntis user parent_account
attr myWebuntis class 5a
attr myWebuntis interval 3600
set myWebuntis password mysecretpassword
```

### Student-Specific Timetable

```
define myWebuntis Webuntis
attr myWebuntis server https://myschool.webuntis.com
attr myWebuntis school myschool
attr myWebuntis user parent_account
attr myWebuntis class 5a
attr myWebuntis timeTableMode student
attr myWebuntis studentID 12345
set myWebuntis password mysecretpassword
```

### With iCal Export

```
define myWebuntis Webuntis
attr myWebuntis server https://myschool.webuntis.com
attr myWebuntis school myschool
attr myWebuntis user parent_account
attr myWebuntis class 5a
attr myWebuntis iCalPath /opt/fhem/www/ical/
set myWebuntis password mysecretpassword
```

### With Exception Filtering

```
define myWebuntis Webuntis
attr myWebuntis server https://myschool.webuntis.com
attr myWebuntis school myschool
attr myWebuntis user parent_account
attr myWebuntis class 5a
attr myWebuntis exceptionIndicator code,info,lstext,lstype,substText
attr myWebuntis exceptionFilter lstext="1.HJ"
attr myWebuntis excludeSubjects Sport,Kunst
attr myWebuntis considerTimeOfDay yes
set myWebuntis password mysecretpassword
```

## Readings

The module creates the following readings:

| Reading | Description |
|---------|-------------|
| `state` | Current module state |
| `lastError` | Last error message (if any) |
| `exceptionCount` | Number of current exceptions |
| `exceptionToday` | Today's exceptions |
| `exceptionTomorrow` | Tomorrow's exceptions |
| `e_01`, `e_02`, ... | Individual exception details |
| `schoolYearName` | Current school year name |
| `schoolYearStart` | School year start date |
| `schoolYearEnd` | School year end date |
| `schoolYearID` | School year ID |

## Troubleshooting

### Authentication Issues

If you see "Authentication Error - Update Password":
1. Verify your credentials work on the Webuntis web interface
2. Update password: `set myWebuntis password <new_password>`
3. Check password status: `get myWebuntis passwordStatus`

### Network Issues

The module automatically retries transient errors (timeouts, connection failures) with exponential backoff. Check the `lastError` reading for details.

### Missing Classes

If the class dropdown is empty:
1. Run `get myWebuntis retrieveClasses`
2. Wait a few seconds
3. Run `get myWebuntis classes` to see available options

## Security Notes

- Passwords are stored securely using FHEM's password store mechanism
- Passwords are never logged (even at debug level)
- The iCal export validates paths to prevent directory traversal attacks
- Use HTTPS URLs for the server attribute

## Version History

See the CHANGED file for detailed version history.
