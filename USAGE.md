# FHEM Webuntis Module - Usage Guide

## Overview

The `69_Webuntis.pm` module retrieves timetable data from the Webuntis school cloud service for use in the FHEM home automation system.

**Note:** Detailed documentation including all attributes, commands, and examples is available directly in FHEM via the built-in help system (click the `?` next to the device).

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

### Option 1: FHEM Update (Recommended)

Add this repository to FHEM's update sources for automatic updates:

```
update add https://raw.githubusercontent.com/tobi01001/FHEM-Webuntis/main/controls_webuntis.txt
update
```

This will:
- Install the module automatically
- Enable automatic updates when new versions are released
- Handle all dependencies correctly

### Option 2: Manual Installation

1. Copy `FHEM/69_Webuntis.pm` to your FHEM modules directory (typically `/opt/fhem/FHEM/`)
2. Restart FHEM or reload the module

## Quick Start

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

### Step 4: Retrieve Timetable

```
get myWebuntis timetable
```

## Further Documentation

For complete documentation including:
- All available commands and attributes
- Example configurations
- Troubleshooting guide
- Security notes

Please refer to the built-in FHEM help by clicking the `?` icon next to your Webuntis device, or see the POD documentation at the end of the module file.

## Version History

See the CHANGED file for detailed version history.
