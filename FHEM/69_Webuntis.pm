# $Id: Webuntis.pm 24293 2023-02-26 22:28:41Z KernSani $
##############################################################################
#
#     98_wEBUNTIS.pm
#     An FHEM Perl module that retrieves information from Webuntis Schoolcloud
#
#     Copyright by KernSani
#
#     Fhem is free software: you can redistribute it and/or modify
#     it under the terms of the GNU General Public License as published by
#     the Free Software Foundation, either version 2 of the License, or
#     (at your option) any later version.
#
#     Fhem is distributed in the hope that it will be useful,
#     but WITHOUT ANY WARRANTY; without even the implied warranty of
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#     GNU General Public License for more details.
#
#     You should have received a copy of the GNU General Public License
#     along with fhem.  If not, see <http://www.gnu.org/licenses/>.
#
##############################################################################
#   Changelog:
#   0.3.00 - 2024-06-10 Bugfixes and Optimizations, new Attribute to set start day of timetable, tobi
#   0.2.01 - 2024-09-02 iCal Erzeugung, andies
#   0.2.00 - 2023-10-27 Bugfixes andd Optimizations, new Attribute to exclude subjects
#   0.1.00 - 2023-02-26 Initial Release
##############################################################################
##############################################################################
#   Todo:
#   *
#
##############################################################################
package main;
use strict;
use warnings;

use constant WEBUNTIS_VERSION => "0.3.00";

package FHEM::Webuntis;

use List::Util qw(any first);
use HttpUtils;
use Data::Dumper;
use FHEM::Meta;
use GPUtils qw(GP_Import GP_Export);
use utf8;
use POSIX qw( strftime );
use DevIo;
use B qw(svref_2object);
use utf8;
use Digest::MD5 qw(md5);

use FHEM::Core::Authentication::Passwords qw(:ALL);
use DateTime; ## include iCal changes
use DateTime::Format::Strptime;
use Time::Local;

# DateTime formatter for YYYYMMDD format used by Webuntis API
my $date_formatter = DateTime::Format::Strptime->new(
    pattern => '%Y%m%d',
    on_error => 'croak',
);

# DateTime formatter for HHMM time format used by Webuntis API  
my $time_formatter = DateTime::Format::Strptime->new(
    pattern => '%H%M',
    on_error => 'croak',
);

use Cwd;
use Encode;

# Module default constants and variables
use constant {
    WU_MINIMUM_INTERVAL => 300,
    LOG_CRITICAL        => 0,
    LOG_ERROR           => 1,
    LOG_WARNING         => 2,
    LOG_SEND            => 3,
    LOG_RECEIVE         => 4,
    LOG_DEBUG           => 5,
};

my $EMPTY = q{};
my $SPACE = q{ };
my $COMMA = q{,};

my @WUattr = ( "server", "school", "user", "exceptionIndicator", "exceptionFilter:textField-long", "excludeSubjects", "iCalPath", "interval", "DaysTimetable", "studentID", "timeTableMode:class,student", "startDayTimeTable:Today,Monday,Tuesday,Wednesday,Thursday,Friday,Saturday,Sunday", "schoolYearStart", "schoolYearEnd", "maxRetries", "retryDelay", "disable" );

#
my $version = "0.2.01";

my $missingModul = '';
eval 'use Digest::SHA qw(sha256);1;' or $missingModul .= 'Digest::SHA ';

#eval 'use Protocol::WebSocket::Client;1' or $missingModul .= 'Protocol::WebSocket::Client ';

# Taken from RichardCZ https://gl.petatech.eu/root/HomeBot/snippets/2
my $got_module = use_module_prio(
    {
        wanted   => [ 'encode_json', 'decode_json' ],
        priority => [
            qw(JSON::MaybeXS
              Cpanel::JSON::XS
              JSON::XS JSON::PP
              JSON::backportPP)
        ],
    }
);
if ( !$got_module ) {
    $missingModul .= 'a JSON module (e.g. JSON::XS) ';
}

# Helper functions for date handling with DateTime
sub format_date_for_api {
    my $datetime = shift;
    return $date_formatter->format_datetime($datetime);
}

sub parse_date_from_api {
    my $date_string = shift;
    return unless defined $date_string && length($date_string) >= 8;
    
    my $dt;
    eval {
        $dt = $date_formatter->parse_datetime($date_string);
    };
    if ($@) {
        # Fallback for malformed dates
        return undef;
    }
    return $dt;
}

sub get_today_as_string {
    my $today = DateTime->now;
    return format_date_for_api($today);
}

sub format_time_for_display {
    my $time_string = shift;
    return '' unless defined $time_string;
    
    if (length($time_string) >= 4) {
        my $hour = substr($time_string, 0, 2);
        my $minute = substr($time_string, 2, 2);
        return "$hour:$minute";
    } elsif (length($time_string) == 3) {
        my $hour = "0" . substr($time_string, 0, 1);
        my $minute = substr($time_string, 1, 2);
        return "$hour:$minute";
    }
    return '';
}

sub format_date_for_display {
    my $date_string = shift;
    return '' unless defined $date_string;
    
    my $dt = parse_date_from_api($date_string);
    return '' unless $dt;
    
    return $dt->strftime("%d.%m.%Y");
}

## Import der FHEM Funktionen
BEGIN {
    GP_Import(
        qw(
          AttrVal
          AttrNum
          CommandDeleteReading
          InternalTimer
          InternalVal
          readingsSingleUpdate
          readingsBulkUpdate
          readingsBulkUpdateIfChanged
          readingsBeginUpdate
          readingsDelete
          readingsEndUpdate
          ReadingsNum
          ReadingsVal
          RemoveInternalTimer
          Log3
          gettimeofday
          deviceEvents
          time_str2num
          latin1ToUtf8
          IsDisabled
          HttpUtils_NonblockingGet
          HttpUtils_BlockingGet
          DevIo_IsOpen
          DevIo_CloseDev
          DevIo_OpenDev
          DevIo_SimpleRead
          DevIo_SimpleWrite
          init_done
          readingFnAttributes
          setKeyValue
          getKeyValue
          getUniqueId
          defs
          s
          MINUTESECONDS
          makeReadingName
          )
    );
}

#-- Export to main context with different name
GP_Export(
    qw(
      Initialize
      )
);

=pod

=over

=item Initialize($hash)

Initialize the Webuntis module for FHEM. Sets up all required callbacks and attributes.

Parameters:
    $hash - FHEM device hash reference

Returns:
    Result of FHEM::Meta::InitMod()

=back

=cut

sub Initialize {
    my ($hash) = @_;

    $hash->{SetFn}       = \&Set;
    $hash->{GetFn}       = \&Get;
    $hash->{DefFn}       = \&Define;
    $hash->{ReadyFn}     = \&Ready;
    $hash->{ReadFn}      = \&wsReadDevIo;
    $hash->{NotifyFn}    = \&Notify;
    $hash->{UndefFn}     = \&Undefine;
    $hash->{AttrFn}      = \&Attr;
    $hash->{RenameFn}    = \&Rename;
	
	$hash->{AttrList}    = join( $SPACE, @WUattr ).$SPACE."class".$SPACE.$readingFnAttributes;
	$hash->{".AttrList"} = join( $SPACE, @WUattr ).$SPACE."class".$SPACE.$readingFnAttributes;
	
    return FHEM::Meta::InitMod( __FILE__, $hash );
}

=pod

=over

=item Define($hash, $def)

Define a new Webuntis device. Validates parameters and initializes the device.

Parameters:
    $hash - FHEM device hash reference
    $def  - Definition string from FHEM command

Returns:
    undef on success, error message on failure

=back

=cut

sub Define {
    my $hash = shift;
    my $def  = shift;

    return $@ if ( !FHEM::Meta::SetInternals($hash) );

    my @args = split m{\s+}, $def;

    return "Cannot define device. Please install perl modules $missingModul."
      if ($missingModul);

    my $usage = qq (syntax: define <name> Webuntis);
    return $usage if ( @args != 2 );

    my ( $name, $type ) = @args;

    Log3 $name, LOG_SEND, "[$name] Webuntis defined $name";

    $hash->{NAME}    = $name;
    $hash->{VERSION} = $version;
    if ( AttrVal( $name, "exceptionIndicator", $EMPTY ) eq $EMPTY ) {
        ::CommandAttr( undef, $name . " exceptionIndicator code,info,lstext,lstype,substText" );
    }

    $hash->{helper}->{passObj} = FHEM::Core::Authentication::Passwords->new( $hash->{TYPE} );

    # Initialize password validation status
    if (defined(ReadPassword($hash))) {
        $hash->{helper}{passwordValid} = 0;  # Unknown until first successful authentication
    }

	getTimeTable($hash);

    #start timer
    if ( !IsDisabled($name) && $init_done && defined( ReadPassword($hash) ) ) {
         my $next = int( gettimeofday() ) + 1;
         InternalTimer( $next, 'FHEM::Webuntis::wuTimer', $hash, 0 );
     }
     if ( IsDisabled($name) ) {
         readingsSingleUpdate( $hash, "state", "inactive", 1 );
         $hash->{helper}{DISABLED} = 1;
     }
    return;
}

=pod

=over

=item Undefine($hash)

Clean up when a Webuntis device is undefined. Removes timers and closes connections.

Parameters:
    $hash - FHEM device hash reference

Returns:
    undef

=back

=cut

sub Undefine {
    my $hash = shift;
    RemoveInternalTimer($hash);
    DevIo_CloseDev($hash);
    # Clear any running timer operations
    clearTimerOperation($hash);
    return;
}

=pod

=over

=item Notify($hash, $dev)

Handle FHEM system notifications. Starts timers when FHEM is initialized.

Parameters:
    $hash - FHEM device hash reference
    $dev  - Triggering device hash reference

Returns:
    undef

=back

=cut

sub Notify {
    my ( $hash, $dev ) = @_;
    my $name = $hash->{NAME};               # own name / hash
    my $events = deviceEvents( $dev, 1 );

    return if ( IsDisabled($name) );
    return if ( !any { m/^INITIALIZED|REREADCFG$/xsm } @{$events} );

    my $next = int( gettimeofday() ) + 1;
    InternalTimer( $next, 'FHEM::Webuntis::wuTimer', $hash, 0 );
    return;
}

=pod

=over

=item Set($hash, $name, $cmd, $arg, $val)

Handle set commands for the Webuntis device. Supports setting password, retrieving timetables and school years.

Parameters:
    $hash - FHEM device hash reference
    $name - Device name
    $cmd  - Command to execute
    $arg  - Command argument (optional)
    $val  - Command value (optional)

Returns:
    undef on success, error message on failure

=back

=cut

sub Set {
    my $hash = shift;
    my $name = shift;
    my $cmd  = shift // return qq (Set $name needs at least one argument);
    my $arg  = shift;
    my $val  = shift;

    if ( $cmd eq 'password' ) {

        my $err = StorePassword( $hash, $arg );
        # Reset password validation status when new password is set
        delete $hash->{helper}{passwordValid};
        delete $hash->{READINGS}{lastError}; # Clear any previous authentication errors
        
        if ( !IsDisabled($name) && defined( ReadPassword($hash) ) ) {
            my $next = int( gettimeofday() ) + 1;
            InternalTimer( $next, 'FHEM::Webuntis::wuTimer', $hash, 0 );
        }
        return $err;

    }
    return qq (Unknown argument $cmd, choose one of password);
}

=pod

=over

=item Get($hash, $name, $cmd)

Handle get commands for the Webuntis device. Supports getting password status and other information.

Parameters:
    $hash - FHEM device hash reference
    $name - Device name
    $cmd  - Command to execute

Returns:
    Command result or error message

=back

=cut

sub Get {
    my $hash = shift;
    my $name = shift;
    my $cmd  = shift // return "get $name needs at least one argument";

    if ( !ReadPassword($hash) ) {
         return qq(set password first);
    }

    # Check if password was previously marked as invalid
    if (defined($hash->{helper}{passwordValid}) && $hash->{helper}{passwordValid} == 0) {
        return qq(Authentication failed - please update password: set $name password <new_password>);
    }

    clearTimerOperation($hash);

    if ( $cmd eq 'timetable' ) {
        return getTimeTable($hash);
    }
    if ( $cmd eq 'classes' ) {
        return getClasses($hash);
    }
    if ( $cmd eq 'retrieveClasses' ) {
        return retrieveClasses($hash);
    }
    if ( $cmd eq 'schoolYear' ) {
        return getSchoolYear($hash);
    }
    if ( $cmd eq 'passwordStatus' ) {
        return getPasswordStatus($hash);
    }
    return qq(Unknown argument $cmd, choose one of timetable:noArg classes:noArg retrieveClasses:noArg schoolYear:noArg passwordStatus:noArg);
}
###################################
# Retrieve school year boundaries from server
###################################
sub getSchoolYear {
    my $hash = shift;
    my $name = $hash->{NAME};

    push @{ $hash->{helper}{cmdQueue} }, \&login;
    push @{ $hash->{helper}{cmdQueue} }, \&getSchoolYearAPI;
    processCmdQueue($hash);
    return "Retrieving school year, please watch readings";
}

sub getSchoolYearAPI {
    my $hash = shift;
    my $name = $hash->{NAME};

    my $param->{header} = {
        "Accept"          => "*/*",
        "Content-Type"    => "application/json",
        "Accept-Encoding" => "br, gzip, deflate",
        "Connection"      => "keep-alive",
        "Cookie"          => $hash->{helper}{cookies}
    };
    my %body = (
        "id"      => "FHEM",
        "jsonrpc" => "2.0",
        "method"  => "getSchoolyears",
    );
    $param->{data}     = encode_json( \%body );
    $param->{method}   = "POST";
    $param->{url}      = AttrVal( $name, "server", "" ) . "/WebUntis/jsonrpc.do?school=" . AttrVal( $name, "school", $EMPTY );
    $param->{callback} = \&parseSchoolYear;
    $param->{hash}     = $hash;
    Log3($name,LOG_SEND,"getSchoolYearAPI sends".$param->{data}." to ".$param->{url});
    my ( $err, $data ) = HttpUtils_NonblockingGet($param);
}

sub parseSchoolYear {
    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ($err) {
        return if handleRetryOrFail($hash, $err, "parseSchoolYear");
        return;
    }
    $data = latin1ToUtf8($data);
    Log3( $name, LOG_RECEIVE, "getSchoolYear received $data");
    my $json = safe_decode_json( $hash, $data );
    if (!$json) {
        return if handleRetryOrFail($hash, "No JSON received for SchoolYear", "parseSchoolYear");
        return;
    }
    if ( $json->{error} ) {
        my $errorCode = $json->{error}{code};
        return if handleRetryOrFail($hash, $json->{error}{message}, "parseSchoolYear", $errorCode);
        return;
    }

    # Success - reset retry count
    delete $hash->{helper}{retryCount};

    my @years = @{ $json->{result} };
    # Find current school year (where today is between startDate and endDate)
    my $today = get_today_as_string();
    my ($currentStart, $currentEnd, $currentName);
    my $currentId;
    foreach my $year (@years) {
        if ($today ge $year->{startDate} && $today le $year->{endDate}) {
            $currentStart = $year->{startDate};
            $currentEnd = $year->{endDate};
            $currentName = $year->{name};
            $currentId = $year->{id};
            Log3 $name, LOG_DEBUG, "[$name] Current school year found: $currentName ($currentStart to $currentEnd)" ;
            #Log3 $name, LOG_DEBUG, "[$name] Current Year Data: ".Dumper($year) ;
            last;
        }
    }
    # If not found, use the last year
    if (!$currentStart && @years) {
        $currentStart = $years[-1]->{startDate};
        $currentEnd = $years[-1]->{endDate};
        $currentName = $years[-1]->{name};
            $currentId = $years[-1]->{id};
    }
    readingsSingleUpdate( $hash, "schoolYearName", $currentName, 1 );
    readingsSingleUpdate( $hash, "schoolYearStart", $currentStart, 1 );
    readingsSingleUpdate( $hash, "schoolYearEnd", $currentEnd, 1 );
    readingsSingleUpdate( $hash, "schoolYearID", $currentId, 1 );
    readingsSingleUpdate( $hash, "state", "schoolYear updated", 1 );
    processCmdQueue($hash);
    return;
}

sub Attr {
    my $cmd  = shift;
    my $name = shift;
    my $attr = shift;
    my $aVal = shift;

    my $hash = $defs{$name};

    if ( $cmd eq 'set' ) {
        if ( $attr eq 'interval' ) {

            # restrict interval to 5 minutes
            if ( $aVal > WU_MINIMUM_INTERVAL ) {
                my $next = int( gettimeofday() ) + 1;
                InternalTimer( $next, 'FHEM::Webuntis::wuTimer', $hash, 0 );
                return;
            }

            # message if interval is less than 5 minutes
            if ( $aVal > 0 ) {
                return qq (Interval for $name has to be > 5 minutes (300 seconds) or 0 to disable);
            }
            RemoveInternalTimer($hash);
            # Clear any running timer operations when interval is disabled
            delete $hash->{helper}{timerRunning};
            return;
        }
        if ( $attr eq 'disable' ) {
            if ( $aVal == 1 ) {
                RemoveInternalTimer($hash);
                DevIo_CloseDev($hash);
                readingsSingleUpdate( $hash, "state", "inactive", 1 );
                $hash->{helper}{DISABLED} = 1;
                # Clear any running timer operations when disabled
                delete $hash->{helper}{timerRunning};
                return;
            }
            if ( $aVal == 0 ) {
                readingsSingleUpdate( $hash, "state", "initialized", 1 );
                $hash->{helper}{DISABLED} = 0;
                my $next = int( gettimeofday() ) + 1;
                InternalTimer( $next, 'FHEM::Webuntis::wuTimer', $hash, 0 );
                return;
            }
            return qq (Attribute disable for $name has to be 0 or 1);
        }
        # Validate schoolYearStart: format and logical consistency
        if ( $attr eq 'schoolYearStart' ) {
            if ( $aVal !~ /^\d{4}\-\d{2}\-\d{2}$/ ) {
                return qq (Attribute schoolYearStart for $name has to be in format YYYY-MM-DD);
            }
            # Check logical consistency with schoolYearEnd if it exists
            my $endDate = AttrVal( $name, "schoolYearEnd", "" );
            if ( $endDate ne "" && $aVal ge $endDate ) {
                return qq (Attribute schoolYearStart for $name must be before schoolYearEnd ($endDate));
            }
        }
        # Validate schoolYearEnd: format and logical consistency
        if ( $attr eq 'schoolYearEnd' ) {
            if ( $aVal !~ /^\d{4}\-\d{2}\-\d{2}$/ ) {
                return qq (Attribute schoolYearEnd for $name has to be in format YYYY-MM-DD);
            }
            # Check logical consistency with schoolYearStart if it exists
            my $startDate = AttrVal( $name, "schoolYearStart", "" );
            if ( $startDate ne "" && $aVal le $startDate ) {
                return qq (Attribute schoolYearEnd for $name must be after schoolYearStart ($startDate));
            }
        }
        if ( $attr eq 'maxRetries' ) {
            if ( $aVal !~ /^\d+$/ || $aVal < 0 || $aVal > 10 ) {
                return qq (Attribute maxRetries for $name has to be a number between 0 and 10);
            }
        }
        if ( $attr eq 'retryDelay' ) {
            if ( $aVal !~ /^\d+$/ || $aVal < 5 || $aVal > 300 ) {
                return qq (Attribute retryDelay for $name has to be a number between 5 and 300 seconds);
            }
        }
    }

    if ( $cmd eq "del" ) {
        if ( $attr eq "interval" ) {
            RemoveInternalTimer($hash);
            return;
        }
        if ( $attr eq "disable" ) {
            readingsSingleUpdate( $hash, "state", "initialized", 1 );
            $hash->{helper}{DISABLED} = 0;
            # Clear any previous timer state when re-enabling
            delete $hash->{helper}{timerRunning};
            my $next = int( gettimeofday() ) + 1;
            InternalTimer( $next, 'FHEM::Webuntis::wuTimer', $hash, 0 );
            return;
        }
    }
    return;
}

sub wuTimer {
    my $hash = shift;

    my $name = $hash->{NAME};
    
    # Check if another timer operation is already in progress
    if ( $hash->{helper}{timerRunning} ) {
        Log3 $name, LOG_WARNING, qq([$name]: Timer already running, skipping this execution);
        # Use shorter recheck interval (30 seconds) instead of full interval to allow quicker recovery
        my $next = int( gettimeofday() ) + 30;
        InternalTimer( $next, 'FHEM::Webuntis::wuTimer', $hash, 0 );
        return;
    }
    
    # Set flag to indicate timer operation is in progress
    $hash->{helper}{timerRunning} = 1;
    
    RemoveInternalTimer($hash);
    getTimeTable($hash);
    Log3 $name, LOG_RECEIVE, qq([$name]: Starting Timer);
    
    # Schedule next timer - will be rescheduled when current operation completes
    my $next = int( gettimeofday() ) + AttrNum( $name, 'interval', 3600 );
    InternalTimer( $next, 'FHEM::Webuntis::wuTimer', $hash, 0 );
    return;
}

###################################
# Get current password validation status
###################################
sub getPasswordStatus {
    my $hash = shift;
    my $name = $hash->{NAME};
    
    if (!defined(ReadPassword($hash))) {
        return "No password configured - use: set $name password <your_password>";
    }
    
    my $status = $hash->{helper}{passwordValid};
    if (!defined($status)) {
        return "Password status unknown - not yet tested";
    } elsif ($status == 1) {
        return "Password valid - last authentication successful";
    } elsif ($status == 0) {
        my $lastError = ReadingsVal($name, "lastError", "Unknown authentication error");
        return "Password invalid - $lastError";
    } else {
        return "Password status unclear - please check logs";
    }
}

###################################
# subroutine to retrieve classes from server
###################################
sub retrieveClasses {
    my $hash = shift;

    my $name = $hash->{NAME};
    
    push @{ $hash->{helper}{cmdQueue} }, \&login;
    push @{ $hash->{helper}{cmdQueue} }, \&getClass;
    processCmdQueue($hash);
    return;
}

###################################
# subroutine to retrieve classes from server
# returns: "Please maintain Attributes first" or "Retrieving classes, please try again in a second"
###################################
sub getClasses {
    my $hash = shift;
    my $name = $hash->{NAME};
    if (   AttrVal( $name, "school", "NA" ) eq "NA"
        or AttrVal( $name, "server",   "NA" ) eq "NA"
        or AttrVal( $name, "user",     "NA" ) eq "NA"
        or !ReadPassword($hash) )
    {
        return "Please maintain Attributes first";
    }

    if ( $hash->{helper}{classes} ) {
        return $hash->{helper}{classes};
    }

    retrieveClasses($hash);
    return "Retrieving classes, please try again in a second";
}

###################################
sub getTimeTable {
    my $hash = shift;

    my $name = $hash->{NAME};
    if (   AttrVal( $name, "school", "NA" ) eq "NA"
        or AttrVal( $name, "server", "NA" ) eq "NA"
        or AttrVal( $name, "user",   "NA" ) eq "NA"
        or !ReadPassword($hash)
        or AttrVal( $name, "class",  "NA" ) eq "NA" )
    {
        return "Please maintain Attributes first";
    }
    push @{ $hash->{helper}{cmdQueue} }, \&login;
    if (!$hash->{helper}{classMap}) {
        push @{ $hash->{helper}{cmdQueue} }, \&getClass;    
    }
    push @{ $hash->{helper}{cmdQueue} }, \&getTT;
    processCmdQueue($hash);
    return;
}

sub login {
    my $hash = shift;
    my $name = $hash->{NAME};
    Log3 $name, LOG_SEND, "[$name] Starting login";
    my $param->{header} = {
        "Accept"          => "*/*",
        "Content-Type"    => "application/json",
        "Accept-Encoding" => "br, gzip, deflate"
    };

    my %body = (
        "id"      => "FHEM",
        "jsonrpc" => "2.0",
        "method"  => "authenticate",
        "params"  => {
            "password" => ReadPassword($hash),
            "user"     => AttrVal( $name, "user",     $EMPTY ),
            "client"   => "FHEM"
        }
    );

    $param->{data}     = encode_json( \%body );
    $param->{method}   = "POST";
    $param->{url}      = AttrVal( $name, "server", "" ) . "/WebUntis/jsonrpc.do?school=" . AttrVal( $name, "school", $EMPTY );
    $param->{callback} = \&parseLogin;
    $param->{hash}     = $hash;
    # Log only non-sensitive info at normal level
    Log3($name, LOG_SEND, "login sends to " . $param->{url} . " for user " . AttrVal($name, "user", $EMPTY));
    # Log full data at debug level with password redacted
    my $debug_body = { %body };
    $debug_body->{params}{password} = "***REDACTED***" if exists $debug_body->{params}{password};
    #Log3($name, LOG_DEBUG, "login params: ".Dumper($debug_body));
    #Log3($name,LOG_DEBUG,"login params: ".Dumper(\%body));
    #Log3($name,LOG_DEBUG,"login header: ".Dumper($param));
    my ( $err, $data ) = HttpUtils_NonblockingGet($param);

}


sub parseLogin {

    my ( $param, $err, $data ) = @_;
    my $hash    = $param->{hash};
    my $name    = $hash->{NAME};
    my $header  = $param->{httpheader};
    my $cookies = getCookies( $hash, $header );

    if ($err) {
        return if handleRetryOrFail($hash, $err, "parseLogin");
        return;
    }

    my $json = safe_decode_json( $hash, $data );
    Log3( $name, LOG_RECEIVE, "login received $data");
    if (!$json) {
        return if handleRetryOrFail($hash, "No JSON after Login", "parseLogin");
        return;
    } elsif ( $json->{error} ) {
        my $errorCode = $json->{error}{code};
        return if handleRetryOrFail($hash, $json->{error}{message}, "parseLogin", $errorCode);
        return;
    } else {
        # Success - reset retry count and mark password as valid
        delete $hash->{helper}{retryCount};
        $hash->{helper}{passwordValid} = 1;
        delete $hash->{READINGS}{lastError}; # Clear any previous error
		
		my $pType = $json->{result}->{personType} // "None";
		if ($pType eq "12")
		{
			$pType = "Eltern (12)";
		}
		elsif( $pType eq "5" )
		{
			$pType = "Student (5)";
		}
		elsif( $pType eq "2" )
		{
			$pType = "Teacher (2)";
		}
		
		$hash->{PERSONTYPE} = $pType;
		$hash->{PERSONID} = $json->{result}->{personId} // "None";
		$hash->{KLASSENID} = $json->{result}->{klasseId} // "None";
		
		if ($hash->{KLASSENID} ne "None" and $hash->{KLASSENID} ne "0")
		{
			$hash->{KLASSENNAME} = $hash->{helper}{classIdMap}{$hash->{KLASSENID}} // "id not found";
		}
		else
		{
			delete $hash->{KLASSENID};
			delete $hash->{KLASSENNAME};
		}
	}
    if ( $hash->{HTTPCookieHash} ) {
        foreach my $cookie ( sort keys %{ $hash->{HTTPCookieHash} } ) {
            my $cPath = $hash->{HTTPCookieHash}{$cookie}{Path};
            $cookies .= "; " if ($cookies);
            $cookies .= $hash->{HTTPCookieHash}{$cookie}{Name} . "=" . $hash->{HTTPCookieHash}{$cookie}{Value};
        }
    }

    $hash->{helper}{cookies} = $cookies;
    processCmdQueue($hash);
    return;
}

sub getClass {
    my $hash = shift;
    my $name = $hash->{NAME};

    my $param->{header} = {
        "Accept"          => "*/*",
        "Content-Type"    => "application/json",
        "Accept-Encoding" => "br, gzip, deflate",
        "Connection"      => "keep-alive",
        "Cookie"          => $hash->{helper}{cookies}
    };
    my %body = (
        "id"      => "FHEM",
        "jsonrpc" => "2.0",
        "method"  => "getKlassen",
    );
    $param->{data}     = encode_json( \%body );
    $param->{method}   = "POST";
    $param->{url}      = AttrVal( $name, "server", "" ) . "/WebUntis/jsonrpc.do?school=" . AttrVal( $name, "school", $EMPTY );
    $param->{callback} = \&parseClass;
    $param->{hash}     = $hash;
    Log3($name,LOG_SEND,"getClass sends".$param->{data}." to ".$param->{url});
    my ( $err, $data ) = HttpUtils_NonblockingGet($param);

}

sub getTT {
    my $hash = shift;
    my $name = $hash->{NAME};

    my ( $s, $mi, $h, $d, $m, $y, $wday) = localtime();
    my $startDay  = AttrVal( $name, 'startDayTimeTable', 'Today' );
    Log3($name, LOG_DEBUG, "getTT - startDay = $startDay");
    my $startDayDelta = 0;
    if ($startDay ne 'Today') {
        my %weekdays = (
            'Sunday' => 0,
            'Monday' => 1,
            'Tuesday' => 2,
            'Wednesday' => 3,
            'Thursday' => 4,
            'Friday' => 5,
            'Saturday' => 6,
        );
        if(exists $weekdays{$startDay}) {
            $startDayDelta = $wday - $weekdays{$startDay} if(($wday - $weekdays{$startDay}) > 0);
        }
    }
    
    # Use DateTime for date calculations
    my $start_dt = DateTime->now->subtract(days => $startDayDelta);
    my $startdate = format_date_for_api($start_dt);

    my $end_dt = DateTime->now->add(days => AttrNum( $name, 'DaysTimetable', 7 ));
    my $enddate = format_date_for_api($end_dt);

    # Limit to school year boundaries if set (check both attributes and readings)
    my $schoolYearStart = AttrVal($name, 'schoolYearStart', '') || ReadingsVal($name, 'schoolYearStart', '');
    my $schoolYearEnd   = AttrVal($name, 'schoolYearEnd', '') || ReadingsVal($name, 'schoolYearEnd', '');
    if ($schoolYearStart ne '' && $startdate lt $schoolYearStart) {
        $startdate = $schoolYearStart;
    }
    if ($schoolYearEnd ne '' && $enddate gt $schoolYearEnd) {
        $enddate = $schoolYearEnd;
    }

    if($startdate gt $enddate) {
        Log3 $name, LOG_ERROR, "[$name] Start date ($startdate) is after end date ($enddate). Please check your settings.";
        readingsSingleUpdate( $hash, "state", "Error: Start date after end date", 1 );
        
        return;
    }

    my $param->{header} = {
        "Accept"          => "*/*",
        "Content-Type"    => "application/json",
        "Accept-Encoding" => "br, gzip, deflate",
        "Connection"      => "keep-alive",
        "Cookie"          => $hash->{helper}{cookies}
    };
    my $param_id = $hash->{helper}{classMap}{ AttrVal( $name, "class", $EMPTY ) };
    my $param_type = 1;
    if( AttrVal($name, "timeTableMode", "class") eq "student" and AttrVal($name, "studentID", "NA") ne "NA") {
        $param_id = AttrVal($name, "studentID", "NA");
        $param_type = 5;
    }

    my %body = (
        "id"      => "FHEM",
        "jsonrpc" => "2.0",
        "method"  => "getTimetable",
        "params"  => [
            {
                "element" => {
                    "id"   => $param_id,
                    "type" => $param_type
                },
                "startDate"        => $startdate,
                "endDate"          => $enddate,
                "showLsText"       => JSON::true,
                "showStudentgroup" => JSON::true,
                "showLsNumber"     => JSON::true,
                "showSubstText"    => JSON::true,
                "showInfo"         => JSON::true,
                "showBooking"      => JSON::true,
                "klasseFields"     => [ "id", "name", "longname", "externalkey" ],
                "roomFields"       => [ "id", "name", "longname", "externalkey" ],
                "subjectFields"    => [ "id", "name", "longname", "externalkey" ],
                "teacherFields"    => [ "id", "name", "longname", "externalkey" ]
            }
        ]
    );

    $param->{data}     = encode_json( \%body );
    $param->{method}   = "POST";
    $param->{url}      = AttrVal( $name, "server", "" ) . "/WebUntis/jsonrpc.do?school=" . AttrVal( $name, "school", $EMPTY );
    $param->{callback} = \&parseTT;
    $param->{hash}     = $hash;
    Log3($name,LOG_SEND,"getTT sends".$param->{data}." to ".$param->{url});
    my ( $err, $data ) = HttpUtils_NonblockingGet($param);
    return;
}

sub parseClass {
    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    if ($err) {
        return if handleRetryOrFail($hash, $err, "parseClass");
        return;
    }
    $data = latin1ToUtf8($data);
    Log3( $name, LOG_RECEIVE, "getClass received $data");
    my $json = safe_decode_json( $hash, $data );
    if (!$json) {
        return if handleRetryOrFail($hash, "No JSON received for Class", "parseClass");
        return;
    }
    if ( $json->{error} ) {
        my $errorCode = $json->{error}{code};
        return if handleRetryOrFail($hash, $json->{error}{message}, "parseClass", $errorCode);
        return;
    }

    # Success - reset retry count
    delete $hash->{helper}{retryCount};

    my @dat    = @{ $json->{result} };
    my @fields = ( "id", "name", "longName" );
    my $html   = "<html><table>\n";
    my %classMap;
	my %classIdMap;
	my $className = "";
	my @classNames;
    foreach my $d (@dat) {
        $html .= "<tr>";
		$className = $d->{name};
		$className =~ s/[^a-zA-Z0-9_]/_/g;
		push(@classNames, $className);
        $classMap{ $className } = $d->{id};
		$classIdMap{ $d->{id} } = $className;
        foreach my $f (@fields) {
            $html .= "<td>";
            if ( $d->{$f} ) {
				if($d->{$f} eq "name")
				{
					$html .= escapeHTML($className);
				}
				else
				{
					$html .= escapeHTML($d->{$f});
				}
                
            }
			else
			{
				$html .= "&nbsp;-&nbsp;";
			}
            $html .= "&nbsp;</td>\n";
        }
        $html .= "</tr>\n";
    }
	my $classes = join(',', sort @classNames); #(keys %classMap));
	
    $html .= "</table></html>";
    $hash->{helper}{classMap} = \%classMap;
	$hash->{helper}{classIdMap} = \%classIdMap;
    $hash->{helper}{classes}  = $html;
	
	Log3 $name, LOG_DEBUG, "[$name] Classlist (attributes): $classes}" ;
	Log3 $name, LOG_DEBUG, "[$name] Classlist (html): $html}" ;
	#$hash->{AttrList} = join( $SPACE, @WUattr ).$SPACE."class:".$classes.$SPACE.$readingFnAttributes;
	$hash->{".AttrList"} = join( $SPACE, @WUattr ).$SPACE."class:$classes".$SPACE.$readingFnAttributes;
    return;
}

=pod

=over

=item _handleTimetableResponse($hash, $data)

Handle and validate the JSON response from Webuntis timetable API.

Parameters:
    $hash - FHEM device hash reference
    $data - Raw response data from API

Returns:
    Decoded JSON hash reference or undef on error

=back

=cut

sub _handleTimetableResponse {
    my ($hash, $data) = @_;
    my $name = $hash->{NAME};
    
    $data = latin1ToUtf8($data);
    Log3($name, LOG_RECEIVE, "getTT received $data");
    
    my $json = safe_decode_json($hash, $data);
    if (!$json) {
        return if handleRetryOrFail($hash, "No JSON received for Timetable", "parseTT");
        return;
    }
    
    if (!exists $json->{result} || ref($json->{result}) ne 'ARRAY') {
        return if handleRetryOrFail($hash, "Invalid JSON structure in timetable response", "parseTT");
        return;
    }
    
    

    return $json;
}

=pod

=over

=item _calculateTimetableDates($hash, $json)

Calculate start and end dates for timetable display.

Parameters:
    $hash - FHEM device hash reference
    $json - Decoded JSON response

Returns:
    Array reference containing (startDate, endDate) as DateTime objects

=back

=cut

sub _calculateTimetableDates {
    my ($hash, $json) = @_;
    my $name = $hash->{NAME};
    
    my $startDate;
    my $endDate;
    
    # Find date range from timetable data
    if (@{$json->{result}} > 0) {
        my @dates = map { $_->{date} } @{$json->{result}};
        @dates = sort @dates;
        
        $startDate = parse_date_from_api($dates[0]);
        $endDate = parse_date_from_api($dates[-1]);
    }
    
    # Use current date if no data found
    unless ($startDate && $endDate) {
        $startDate = DateTime->now();
        $endDate = $startDate->clone();
    }
    
    return [$startDate, $endDate];
}

=pod

=over

=item _checkException($hash, $tt_entry, $exception_indicators)

Check if a timetable entry matches exception criteria.

Parameters:
    $hash - FHEM device hash reference
    $tt_entry - Single timetable entry hash reference
    $exception_indicators - Array reference of exception indicator strings

Returns:
    1 if entry is an exception, 0 otherwise

=back

=cut

sub _checkException {
    my ($hash, $tt_entry, $exception_indicators) = @_;
    my $name = $hash->{NAME};
    Log3 $name, LOG_DEBUG, "Checking entry for exceptions (presence only): ".Dumper($tt_entry);
    Log3 $name, LOG_DEBUG, "Exception indicators: ".Dumper($exception_indicators);
    return 0 unless $exception_indicators && @$exception_indicators;

    for my $indicator (@$exception_indicators) {
        next if $indicator eq '';
        # If the field is present in the entry, it's an exception
        if (exists $tt_entry->{$indicator} && defined $tt_entry->{$indicator}) {
            Log3 $name, LOG_DEBUG, "Exception detected: field '$indicator' is present";
            return 1;
        }
    }
    Log3 $name, LOG_DEBUG, "No exception indicators present for entry.";
    return 0;
}

=pod

=over

=item _buildTimetableRow($hash, $tt_entry, $date_str)

Build an HTML table row for a timetable entry.

Parameters:
    $hash - FHEM device hash reference
    $tt_entry - Single timetable entry hash reference
    $date_str - Date string for display

Returns:
    HTML string for table row

=back

=cut

sub _buildTimetableRow {
    my ($hash, $tt_entry, $date_str) = @_;
    my $name = $hash->{NAME};
    
    my $startTime = format_time_for_display($tt_entry->{startTime});
    my $endTime = format_time_for_display($tt_entry->{endTime});
    my $subject = '';
    my $room = '';
    
    # Extract subject information
    if (exists $tt_entry->{su} && ref($tt_entry->{su}) eq 'ARRAY' && @{$tt_entry->{su}}) {
        $subject = $tt_entry->{su}[0]{longname} || $tt_entry->{su}[0]{name} || '';
    }
    
    # Extract room information
    if (exists $tt_entry->{ro} && ref($tt_entry->{ro}) eq 'ARRAY' && @{$tt_entry->{ro}}) {
        $room = $tt_entry->{ro}[0]{longname} || $tt_entry->{ro}[0]{name} || '';
    }
    
    # Escape HTML entities
    $subject = escapeHTML($subject);
    $room = escapeHTML($room);
    
    return "<tr><td>$date_str</td><td>$startTime</td><td>$endTime</td><td>$subject</td><td>$room</td></tr>";
}

=pod

=over

=item _addToReadingList($hash, $readings_list, $tt_entry, $date_str, $reading_name)

Add timetable entry information to readings list.

Parameters:
    $hash - FHEM device hash reference
    $readings_list - Hash reference of readings to update
    $tt_entry - Single timetable entry hash reference
    $date_str - Date string for reading names
    $reading_name - Base name for reading

Returns:
    undef

=back

=cut

sub _addToReadingList {
    my ($hash, $readings_list, $tt_entry, $date_str, $reading_name) = @_;
    my $name = $hash->{NAME};
    
    my $startTime = format_time_for_display($tt_entry->{startTime});
    my $endTime = format_time_for_display($tt_entry->{endTime});
    
    # Extract subject and room info
    my $subject = '';
    my $room = '';
    
    if (exists $tt_entry->{su} && ref($tt_entry->{su}) eq 'ARRAY' && @{$tt_entry->{su}}) {
        $subject = $tt_entry->{su}[0]{longname} || $tt_entry->{su}[0]{name} || '';
    }
    
    if (exists $tt_entry->{ro} && ref($tt_entry->{ro}) eq 'ARRAY' && @{$tt_entry->{ro}}) {
        $room = $tt_entry->{ro}[0]{longname} || $tt_entry->{ro}[0]{name} || '';
    }
    
    # Create readings
    $readings_list->{"${reading_name}_startTime"} = $startTime;
    $readings_list->{"${reading_name}_endTime"} = $endTime;
    $readings_list->{"${reading_name}_subject"} = $subject if $subject;
    $readings_list->{"${reading_name}_room"} = $room if $room;
    
    return;
}

=pod

=over

=item parseTT($param, $err, $data)

Parse timetable data from Webuntis API and update device readings.
This function has been refactored into smaller helper functions for better maintainability.

Parameters:
    $param - Parameter hash containing device reference
    $err   - Error message if request failed
    $data  - JSON response data from Webuntis API

Returns:
    undef

=back

=cut

sub parseTT {
    my ($param, $err, $data) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    CommandDeleteReading(undef, "$name e_.*");

    if ($err) {
        return if handleRetryOrFail($hash, $err, "parseTT");
        return;
    }

    # Handle and validate JSON response
    my $json = _handleTimetableResponse($hash, $data);
    return unless $json;

    if ($json->{error}) {
        my $errorCode = $json->{error}{code};
        return if handleRetryOrFail($hash, $json->{error}{message}, "parseTT", $errorCode);
        return;
    }

    # Success - reset retry count
    delete $hash->{helper}{retryCount};

    my @dat = @{$json->{result}};
    
    # Calculate timetable date range
    my $dates = _calculateTimetableDates($hash, $json);
    my ($startDate, $endDate) = @$dates;

    # Process exception indicators and filters
    my @exceptionIndicators = split(',', AttrVal($name, "exceptionIndicator", ""));
    my $exceptionFilter = AttrVal($name, "exceptionFilter", "");
    my @excludeSubjects = split(',', AttrVal($name, "excludeSubjects", ""));

    # Initialize readings and HTML content
    my %readings = ();
    my $html = "<html><body><b>" . escapeHTML(AttrVal($name, "alias", $name)) . "</b><table>";
    $html .= "<tr><th>Datum</th><th>von</th><th>bis</th><th>Fach</th><th>Raum</th></tr>";

    my $exceptionCount = 0;
    my $minDate = 99999999;
    my $maxDate = 0;

    Log3 $name, LOG_DEBUG, "Processing ".scalar(@dat)." timetable entries";

    readingsBeginUpdate($hash);


    # Build exception lists for today and tomorrow
    my $lists = { rToday => '', rTomorrow => '' };
    my $today_str = format_date_for_api(DateTime->now);
    my $tomorrow_str = format_date_for_api(DateTime->now->add(days => 1));
    # Process each timetable entry
    for my $tt (@dat) {
        # Track date range
        if ($tt->{date} && $tt->{date} < $minDate) {
            $minDate = $tt->{date};
        }
        if ($tt->{date} && $tt->{date} > $maxDate) {
            $maxDate = $tt->{date};
        }

        # Check for exceptions
        my $isException = _checkException($hash, $tt, \@exceptionIndicators);
        
        Log3 $name, LOG_DEBUG, "Entry date: $tt->{date}, isException: $isException";

        if ($isException) {
            $exceptionCount++;
        }

        

        if ($tt->{date} eq $today_str) {
            $lists->{rToday} .= ($lists->{rToday} ? $COMMA : '') . ($tt->{startTime} // '');
        }
        if ($tt->{date} eq $tomorrow_str) {
            $lists->{rTomorrow} .= ($lists->{rTomorrow} ? $COMMA : '') . ($tt->{startTime} // '');
        }

        my $date_str = format_date_for_display($tt->{date});
        my $startTime = format_time_for_display($tt->{startTime});
        my $endTime = format_time_for_display($tt->{endTime});

        # Extract subject, room, and teacher information
        my $subject = "";
        my $room = "";
        my $teacher = "";

        if ($tt->{su}) {
            if (ref $tt->{su} eq 'ARRAY') {
                $subject = $tt->{su}[0]{longname} || $tt->{su}[0]{name} || "";
            } else {
                $subject = $tt->{su};
            }
            # Skip excluded subjects
            next if any { $subject =~ m{\Q$_\E}i } @excludeSubjects;
        }

        if ($tt->{ro}) {
            if (ref $tt->{ro} eq 'ARRAY') {
                $room = $tt->{ro}[0]{longname} || $tt->{ro}[0]{name} || "";
            } else {
                $room = $tt->{ro};
            }
        }

        if ($tt->{te}) {
            if (ref $tt->{te} eq 'ARRAY') {
                $teacher = $tt->{te}[0]{longname} || $tt->{te}[0]{name} || "";
            } else {
                $teacher = $tt->{te};
            }
        }

        # Build HTML row
        $html .= "<tr><td>$date_str</td><td>$startTime</td><td>$endTime</td>";
        $html .= "<td>" . escapeHTML($subject) . "</td><td>" . escapeHTML($room) . "</td></tr>";

        # Create readings
        my $readingPrefix = $isException ? "e_" : "t_";
        my $readingName = $readingPrefix . $tt->{date} . "_" . $tt->{startTime};
        
        readingsBulkUpdate($hash, $readingName . "_startTime", $startTime);
        readingsBulkUpdate($hash, $readingName . "_endTime", $endTime);
        readingsBulkUpdate($hash, $readingName . "_subject", $subject) if $subject;
        readingsBulkUpdate($hash, $readingName . "_room", $room) if $room;
        readingsBulkUpdate($hash, $readingName . "_teacher", $teacher) if $teacher;

        # Apply exception filter for exceptions
        # Write exception readings if this is an exception and passes filter
        if ($isException) {
            # If exceptionFilter is set, skip if any field matches the filter
            if ($exceptionFilter) {
                if (($tt->{lstext} && $tt->{lstext} =~ m{\Q$exceptionFilter\E}i) ||
                    ($tt->{lstype} && $tt->{lstype} =~ m{\Q$exceptionFilter\E}i) ||
                    ($tt->{substText} && $tt->{substText} =~ m{\Q$exceptionFilter\E}i)) {
                    next;
                }
            }
            # Write exception reading (numbered)
            my $rn = ::makeReadingName("e_" . sprintf("%02d", $exceptionCount));
            my $reading_value = join(',', 
            "date=$tt->{date}",
            "startTime=$tt->{startTime}",
            "endTime=$tt->{endTime}",
            (defined $subject ? "subject=$subject" : ()),
            (defined $room ? "room=$room" : ()),
            (defined $teacher ? "teacher=$teacher" : ()),
            (defined $tt->{lstype} ? "lstype=$tt->{lstype}" : ()),
            (defined $tt->{lstext} ? "lstext=$tt->{lstext}" : ()),
            (defined $tt->{substText} ? "substText=$tt->{substText}" : ()),
            (defined $tt->{info} ? "info=$tt->{info}" : ()),
            (defined $tt->{code} ? "code=$tt->{code}" : ()),
            );
            readingsBulkUpdate($hash, $rn, $reading_value);
        }
    }

    $html .= "</table></body></html>";
    

    

    readingsBulkUpdate($hash, "exceptionToday", join($COMMA, uniq(split($COMMA, $lists->{rToday}))));
    readingsBulkUpdate($hash, "exceptionTomorrow", join($COMMA, uniq(split($COMMA, $lists->{rTomorrow}))));
    readingsBulkUpdate($hash, "state", "processing done");

    # Optionally export to iCal if enabled
    exportTT2iCal($hash);
    # Update summary readings
    readingsBulkUpdate($hash, "timetable", $html);
    readingsBulkUpdate($hash, "exceptionCount", $exceptionCount);
    readingsBulkUpdate($hash, "startDate", format_date_for_display($minDate));
    readingsBulkUpdate($hash, "endDate", format_date_for_display($maxDate));
    readingsBulkUpdate($hash, "lastUpdate", time_str2num(time()));
    
    readingsEndUpdate($hash, 1);
    
    # Clear timer operation flag
    delete $hash->{helper}{timerRunning};
    
    return;
}

sub simpleTable {
    my $name = shift;
    my $pattern = shift;
    my $cnt = ReadingsNum($name, "exceptionCount",0);
    my $html = "<html><body><b>".escapeHTML(AttrVal($name,"alias",$name))."</b><table>";

    my @fields;
    if ($pattern) {
        @fields = split($COMMA,$pattern);
    }
    else {
        @fields = ( "date", "startTime", "endTime", "lstype", "code", "info", "substText", "lstext", "activityType", "ro:longname", "ro:name", "su:longname","su:name", "te:longname", "te:name" );
    }
	my %codeMap = (irregular=>"Vertretung",cancelled=>"Entfall");
    for (my $i = 1;$i <= $cnt; $i++) {
        my ($a, $h) = ::parseParams(ReadingsVal($name,"e_" . sprintf( "%02d", $i ),"" ));
        $html .= "<tr>";
        
        foreach my $f (@fields) {
            my $formatted;
			my $val = $h->{$f} // 'default';  # default to empty string if undef
            if ($f =~ /date/) {
                $formatted = format_date_for_display($val);
                if (!$formatted && $val ne 'default') {
                    Log3 ($name, LOG_ERROR, "SimpleTable: Date string could not be parsed: $val");
                }
            }
            elsif ($f =~ /Time/) {
				$formatted = format_time_for_display($val);
                if (!$formatted && $val ne 'default') {
                    Log3 ($name, LOG_ERROR, "SimpleTable: Time string could not be parsed: $val");
                }
			}
            elsif ($f eq "code" and $val ne 'default') {
                        $formatted = $codeMap{$val};
			}
            else {
                $formatted = $val;
            }
			if ($formatted) {
				$html .= "<td>".escapeHTML($formatted)."</td>";
			}
        }
        $html .= "</tr>";
    }
    $html .= "</table></body></html>";

}

sub escapeHTML {
    my $text = shift;
    return $text unless defined $text;
    $text =~ s/&/&amp;/g;
    $text =~ s/</&lt;/g;
    $text =~ s/>/&gt;/g;
    $text =~ s/"/&quot;/g;
    $text =~ s/'/&#39;/g;
    return $text;
}

sub uniq {
    my %seen;
    grep !$seen{$_}++, @_;
}

### stolen from HTTPMOD
sub getCookies {
    my $hash   = shift;
    my $header = shift;

    my $name = $hash->{NAME};

    delete $hash->{HTTPCookieHash};

    foreach my $cookie ( $header =~ m/set-cookie: ?(.*)/gix ) {
        if ( $cookie =~ /([^,; ]+)=([^,;\s\v]+)[;,\s\v]*([^\v]*)/x ) {

            Log3 $name, LOG_RECEIVE, qq($name: GetCookies parsed Cookie: $1 Wert $2 Rest $3);
            my $cname = $1;
            my $value = $2;
            my $rest  = ( $3 ? $3 : $EMPTY );
            my $path  = $EMPTY;
            if ( $rest =~ /path=([^;,]+)/xsm ) {
                $path = $1;
            }
            my $key = $cname . ';' . $path;
            $hash->{HTTPCookieHash}{$key}{Name}    = $cname;
            $hash->{HTTPCookieHash}{$key}{Value}   = $value;
            $hash->{HTTPCookieHash}{$key}{Options} = $rest;
            $hash->{HTTPCookieHash}{$key}{Path}    = $path;

        }
    }
    return;
}

sub processCmdQueue {
    my $hash = shift;

    my $name = $hash->{NAME};

    return if ( !defined( $hash->{helper}{cmdQueue} ) );

    my $cmd = shift @{ $hash->{helper}{cmdQueue} };

    return if ref($cmd) ne "CODE";
    my $cv = svref_2object($cmd);
    my $gv = $cv->GV;
    Log3 $name, LOG_RECEIVE, "[$name] Processing Queue: " . $gv->NAME;
    $cmd->($hash);
    return;
}

sub clearTimerOperation {
    my $hash = shift;
    delete $hash->{helper}{cmdQueue};
    delete $hash->{helper}{timerRunning};
    return;
}

sub isAuthenticationError {
    my ($error, $errorCode) = @_;
    
    return 0 if !defined($error);
    
    # Check for WebUntis-specific authentication error codes
    # Common WebUntis authentication error codes: -8504, -8520, -8521, -8522
    return 1 if defined($errorCode) && ($errorCode == -8504 || $errorCode == -8520 || $errorCode == -8521 || $errorCode == -8522);
    
    # Check for common authentication error patterns in message
    return 1 if $error =~ /invalid.*(?:credentials|password|username|login)/i;
    return 1 if $error =~ /authentication.*(?:failed|error)/i;
    return 1 if $error =~ /unauthorized|access.*denied/i;
    return 1 if $error =~ /bad.*(?:credentials|password|username)/i;
    return 1 if $error =~ /wrong.*(?:password|username|credentials)/i;
    return 1 if $error =~ /login.*(?:failed|incorrect|invalid)/i;
    
    return 0;
}

sub isTransientError {
    my $error = shift;
    
    return 0 if !defined($error);
    
    # Network-related transient errors that should be retried
    return 1 if $error =~ /timeout/i;
    return 1 if $error =~ /connection.*(?:refused|reset|failed)/i;
    return 1 if $error =~ /network.*(?:unreachable|error)/i;
    return 1 if $error =~ /temporary.*failure/i;
    return 1 if $error =~ /service.*unavailable/i;
    return 1 if $error =~ /socket.*error/i;
    return 1 if $error =~ /dns.*(?:error|failure)/i;
    return 1 if $error =~ /502|503|504/; # HTTP server errors that are often transient
    
    # JSON parsing errors from incomplete/corrupted data could be transient
    return 1 if $error =~ /malformed JSON/i;
    return 1 if $error =~ /unexpected end of JSON/i;
    
    return 0; # Default to permanent error for safety
}

sub handleAuthenticationError {
    my ($hash, $error, $errorCode, $context) = @_;
    my $name = $hash->{NAME};
    
    # Mark password as invalid
    $hash->{helper}{passwordValid} = 0;
    delete $hash->{helper}{retryCount};
    delete $hash->{helper}{cmdQueue};
    
    my $message = "Authentication failed - Invalid credentials. Please update your password using: set $name password <new_password>";
    Log3 $name, LOG_ERROR, "[$name] $message ($error)";
    readingsSingleUpdate($hash, "state", "Authentication Error - Update Password", 1);
    readingsSingleUpdate($hash, "lastError", $message, 1);
    
    return 0; # Not handled - processing stops
}

sub handleRetryOrFail {
    my ($hash, $error, $context, $errorCode) = @_;
    my $name = $hash->{NAME};
    
    # Check for authentication errors first - these should not be retried
    if (isAuthenticationError($error, $errorCode)) {
        return handleAuthenticationError($hash, $error, $errorCode, $context);
    }
    
    # Get retry configuration from attributes (with defaults)
    my $maxRetries = AttrNum($name, 'maxRetries', 3);
    my $retryDelay = AttrNum($name, 'retryDelay', 30);
    
    # Initialize retry count if not present
    if (!defined($hash->{helper}{retryCount})) {
        $hash->{helper}{retryCount} = 0;
    }
    
    # Check if error is transient and we haven't exceeded max retries
    if (isTransientError($error) && $hash->{helper}{retryCount} < $maxRetries) {
        $hash->{helper}{retryCount}++;
        # Exponential backoff: 30s, 60s, 120s, 240s, etc.
        my $delay = $retryDelay * (2 ** ($hash->{helper}{retryCount} - 1));
        
        Log3 $name, LOG_WARNING, "[$name] Transient error in $context (attempt $hash->{helper}{retryCount}/$maxRetries): $error - retrying in ${delay}s";
        readingsSingleUpdate($hash, "state", "Retry $hash->{helper}{retryCount}/$maxRetries: $error", 1);
        
        # Schedule retry with exponential backoff
        my $next = int(gettimeofday()) + $delay;
        InternalTimer($next, 'FHEM::Webuntis::retryProcessing', $hash, 0);
        
        return 1; # Handled - don't delete queue, preserve for retry
    } else {
        # Permanent error or max retries exceeded - give up
        my $retryInfo = $hash->{helper}{retryCount} > 0 ? " after $hash->{helper}{retryCount} retries" : "";
        Log3 $name, LOG_ERROR, "[$name] Permanent error in $context$retryInfo: $error";
        readingsSingleUpdate($hash, "state", "Error: $error$retryInfo", 1);
        
        # Reset retry count and delete queue - processing stops
        delete $hash->{helper}{retryCount};
        delete $hash->{helper}{cmdQueue};
        
        return 0; # Not handled - queue deleted, processing stops
    }
}

sub retryProcessing {
    my $hash = shift;
    # Continue processing the queue from where we left off after retry delay
    processCmdQueue($hash);
    return;
}

sub safe_decode_json {
    my $hash = shift;
    my $data = shift;
    my $name = $hash->{NAME};

    my $json = undef;
    eval {
        $json = decode_json($data);
        1;
    } or do {
        my $error = $@ || 'Unknown failure';
        Log3 $name, LOG_ERROR, "[$name] - Received invalid JSON: $error" . Dumper($data);

    };
    return $json;
}

# from RichardCz, https://gl.petatech.eu/root/HomeBot/snippets/2

sub use_module_prio {
    my $args_hr = shift // return;    # get named arguments hash or bail out

    my $wanted_lr   = $args_hr->{wanted} //   [];    # get list of wanted methods/functions
    my $priority_lr = $args_hr->{priority} // [];    # get list of modules from most to least wanted

    for my $module ( @{$priority_lr} ) {             # iterate the priorized list of wanted modules
        my $success = eval "require $module";        # require module at runtime, undef if not there
        if ($success) {                              # we catched ourselves a module
            import $module @{$wanted_lr};            # perform the import of the wanted methods
            return $module;
        }
    }

    return;
}

sub StorePassword {
    my $hash     = shift;
    my $password = shift;
    my $name     = $hash->{NAME};

    my ( $passResp, $passErr );
    ( $passResp, $passErr ) = $hash->{helper}->{passObj}->setStorePassword( $name, $password );

    if ( defined($passErr) ) {
        return "error while saving the password - $passErr";
    }

    return "password successfully saved";
}

sub ReadPassword {
    my $hash = shift;
    my $name = $hash->{NAME};

    return $hash->{helper}->{passObj}->getReadPassword($name);
}

sub Rename {
    my $new = shift;
    my $old = shift;

    my $hash = $defs{$new};
    my $name = $hash->{NAME};

    my $oldhash = $defs{$old};
    Log3 $name, 1, Dumper($oldhash) ;

    my ( $passResp, $passErr ) = $hash->{helper}->{passObj}->setRename( $new, $old );

    if ( defined($passErr) ) {
        Log3 $name, LOG_WARNING, "[$name] error while saving the password after rename - $passErr. Please set the password again." ;
    }
    return;
}

=pod

=over

=item _generateICalContent($hash, $readings_data)

Generate the main iCal content from timetable readings.

Parameters:
    $hash - FHEM device hash reference
    $readings_data - Hash reference containing reading names and values

Returns:
    String containing the iCal content body

=back

=cut

sub _generateICalContent {
    my ($hash, $readings_data) = @_;
    my $name = $hash->{NAME};
    my $content = "";
    
    for my $reading_name (sort keys %$readings_data) {
        next unless $reading_name =~ /^t_(\d{8})_(\d{3,4})_startTime$/;
        
        my $date_str = $1;
        my $time_str = $2;
        my $base_reading = "t_${date_str}_${time_str}";
        
        # Get related readings for this time slot
        my $subject = $readings_data->{"${base_reading}_subject"} || "";
        my $room = $readings_data->{"${base_reading}_room"} || "";
        my $start_time = $readings_data->{"${base_reading}_startTime"} || "";
        my $end_time = $readings_data->{"${base_reading}_endTime"} || "";
        
        next unless $subject; # Skip entries without subjects
        
        $content .= _generateICalEvent($hash, $date_str, $start_time, $end_time, $subject, $room);
    }
    
    return $content;
}

=pod

=over

=item _generateICalEvent($hash, $date_str, $start_time, $end_time, $subject, $room)

Generate a single iCal event entry.

Parameters:
    $hash - FHEM device hash reference
    $date_str - Date in YYYYMMDD format
    $start_time - Start time (HH:MM)
    $end_time - End time (HH:MM)
    $subject - Subject/course name
    $room - Room name

Returns:
    String containing the iCal event

=back

=cut

sub _generateICalEvent {
    my ($hash, $date_str, $start_time, $end_time, $subject, $room) = @_;
    my $name = $hash->{NAME};
    
    # Convert time format from HH:MM to HHMMSS
    my ($start_hour, $start_min) = split(':', $start_time);
    my ($end_hour, $end_min) = split(':', $end_time);
    
    my $start_timestamp = "${date_str}T${start_hour}${start_min}00";
    my $end_timestamp = "${date_str}T${end_hour}${end_min}00";
    
    # Create unique ID for this event
    my $uid = "${name}_${date_str}_${start_hour}${start_min}_${subject}";
    $uid =~ s/[^a-zA-Z0-9_]/_/g; # Sanitize UID
    
    my $event = "BEGIN:VEVENT\r\n";
    $event .= "DTSTART:$start_timestamp\r\n";
    $event .= "DTEND:$end_timestamp\r\n";
    $event .= "SUMMARY:$subject\r\n";
    $event .= "LOCATION:$room\r\n" if $room;
    $event .= "UID:$uid\r\n";
    $event .= "END:VEVENT\r\n";
    
    return $event;
}

=pod

=over

=item _determineICalFilePath($hash)

Determine the full file path for the iCal export.

Parameters:
    $hash - FHEM device hash reference

Returns:
    String containing the full file path

=back

=cut

sub _determineICalFilePath {
    my ($hash) = @_;
    my $name = $hash->{NAME};
    my $iCalPath = AttrVal($name, "iCalPath", "");
    
    return "" unless $iCalPath;
    
    # Build platform-appropriate path
    my $path_separator = ($^O eq 'MSWin32') ? '\\' : '/';
    
    # Ensure path ends with separator
    $iCalPath .= $path_separator unless $iCalPath =~ /[\/\\]$/;
    
    return $iCalPath . "${name}.ics";
}

=pod

=over

=item _buildUnixPath($base_path, $filename)

Build a Unix-style file path.

Parameters:
    $base_path - Base directory path
    $filename - File name

Returns:
    String containing the full Unix path

=back

=cut

sub _buildUnixPath {
    my ($base_path, $filename) = @_;
    $base_path =~ s/\/$//; # Remove trailing slash
    return "$base_path/$filename";
}

=pod

=over

=item _buildWindowsPath($base_path, $filename)

Build a Windows-style file path.

Parameters:
    $base_path - Base directory path  
    $filename - File name

Returns:
    String containing the full Windows path

=back

=cut

sub _buildWindowsPath {
    my ($base_path, $filename) = @_;
    $base_path =~ s/\\$//; # Remove trailing backslash
    return "$base_path\\$filename";
}

### To export entire time table into iCal from @Sailor

=pod

=over

=item exportTT2iCal($hash)

Export timetable data to iCal format. This function has been refactored into smaller helper functions for better maintainability.

Parameters:
    $hash - FHEM device hash reference

Returns:
    undef

=back

=cut

sub exportTT2iCal {
    my $hash = shift;
    my $name = $hash->{NAME};
    my $iCalPath = AttrVal($name, "iCalPath", "");

    # Check whether the Attribute iCalPath has been provided otherwise skip export
    return unless $iCalPath;

    Log3($name, LOG_DEBUG, "$name : Webuntis_exportTT2iCal====================================================");

    # Determine full file path
    my $iCalFilePath = _determineICalFilePath($hash);
    return unless $iCalFilePath;

    # Get all current readings
    my %readings_data = ();
    for my $reading_name (keys %{$hash->{READINGS}}) {
        next unless $reading_name =~ /^[te]_\d{8}_\d{3,4}_/; # Only timetable readings
        $readings_data{$reading_name} = ReadingsVal($name, $reading_name, "");
    }

    # Generate iCal content
    my $iCalContent = "BEGIN:VCALENDAR\r\n";
    $iCalContent .= "VERSION:2.0\r\n";
    $iCalContent .= "PRODID:-//FHEM//Webuntis//EN\r\n";
    $iCalContent .= "CALSCALE:GREGORIAN\r\n";
    $iCalContent .= "METHOD:PUBLISH\r\n";

    # Add events
    $iCalContent .= _generateICalContent($hash, \%readings_data);

    $iCalContent .= "END:VCALENDAR\r\n";

    # Write to file
    if (open my $fh, '>', $iCalFilePath) {
        print $fh $iCalContent;
        close $fh;
        Log3($name, LOG_SEND, "$name : iCal file written to: $iCalFilePath");
    } else {
        Log3($name, LOG_ERROR, "$name : Cannot write iCal file to: $iCalFilePath - $!");
    }

    return;
}
1;


=pod
=item_helper
=item_summary Retrieve timetable data from Webuntis
=item_summary_DE Stundenplan-Daten von Webuntis auslesen
=begin html

<a name="Webuntis"></a>
<div>
	<ul>
		The module reads timetable data from Webuntis
		<a name='WebuntisDefine'></a>
		<b>Define</b>
		<ul>
			define the module with <code>define <name> Webuntis </code>. After that, set your password <code>set <name> password <password></code>
		</ul>
		<a name='WebuntisGet'></a>
		<b>Get</b>
		<ul>
			<li><a name='timetable'></a>reads the timetable data from Webuntis</li>
			<li><a name='retrieveClasses'></a>reads the classes from Webuntis</li>
			<li><a name='Classes'></a>display retrieved Classes</li>
			<li><a name='passwordStatus'></a>checks current password validation status</li>
		</ul>
		<a name='WebuntisSet'></a>
		<b>Set</b>
		<ul>
			<li><a name='password'></a>set your WebUntis password. Required initially and when your password changes in WebUntis. The module will detect authentication failures and prompt you to update it when needed.</li>
		</ul>
		<a name='WebuntisAttr'></a>
		<b>Attributes</b>
		<ul>
			<li><a name='class'></a>the class for which timetable data should be retrieved</li>
			<li><a name='school'></a>your school</li>
			<li><a name='server'></a>something like https://server.webuntis.com</li>
			<li><a name='user'></a>your username</li>
			<li><a name='exceptionIndicator'></a>Which fields should be populated to create exception readings</li>
			<li><a name='exceptionFilters'></a>Which field values should not be considered as an exception</li>
			<li><a name='excludeSubjects'></a>Which subjects should be ignored</li>
			<li><a name='interval'></a>polling interval in seconds (defaults to 3600)</li>
			<li><a name='studentID'></a>used to get the student specific timetable instead of class based. Needs attr <code>timeTableMode</code> to be set to Student</li>
			<li><a name='timeTableMode'></a>class: use the class information / id for timetable <br>student: use the studentId to get the student time table.</li>
		</ul>
	</ul>
</div>

=end html

=begin html_DE

<a name=Webuntis></a>
<div>
	<ul>
		Das Modul liest Stundenplan-Daten von Webuntis aus
		<a name='WebuntisDefine'></a>
		<b>Define</b>
        <ul>
			define the module with <code>define <name> Webuntis </code>. After that, set your password <code>set <name> password <password></code>
		</ul>
		<a name='WebuntisGet'></a>
        <b>Get</b>
        <ul>
			<li><a name='timetable'></a>reads the timetable data from Webuntis</li>
			<li><a name='retrieveClasses'></a>reads theclasses from Webuntis</li>
			<li><a name='Classes'></a>display retrieved Classes</li>
			<li><a name='passwordStatus'></a>checks current password validation status</li>
		</ul>
		<a name='WebuntisSet'></a>
        <b>Set</b>
        <ul>
			<li><a name='password'></a>set your WebUntis password. Required initially and when your password changes in WebUntis. The module will detect authentication failures and prompt you to update it when needed.</li>
		</ul>
		<a name='WebuntisAttr'></a>
        <b>Attributes</b>
        <ul>
			<li><a name='class'></a>the class for which timetable data should be retrieved</li>
			<li><a name='school'></a>your school</li>
			<li><a name='server'></a>something like https://server.webuntis.com</li>
			<li><a name='user'></a>your username</li>
			<li><a name='exceptionIndicator'></a>Which fields should be populated to create exception readings</li>
			<li><a name='exceptionFilters'></a>Which field values should not be considered as an exception</li>
			<li><a name='excludeSubjects'></a>Which subjects should be ignored</li>
			<li><a name='interval'></a>polling interval in seconds (defaults to 3600)</li>
			<li><a name='iCalPath'></a>path to write a iCal to - must exist and be writeable by fhem. gets written after getTimeTable</li>
			<li><a name='studentID'></a>used to get the student specific timetable instead of class based. Needs attr <code>timeTableMode</code> to be set to Student</li>
			<li><a name='timeTableMode'></a>class: use the class information / id for timetable <br>student: use the studentId to get the student time table.</li>
        </ul>
   </ul>
</div>

=end html_DE