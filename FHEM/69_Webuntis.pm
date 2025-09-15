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

use Cwd;
use Encode;

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

# Readonly is recommended, but requires additional module
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

my @WUattr = ( "server", "school", "user", "exceptionIndicator", "exceptionFilter:textField-long", "excludeSubjects", "iCalPath", "interval", "DaysTimetable", "studentID", "timeTableMode:class,student", "startDayTimeTable:Today,Monday,Tuesday,Wednesday,Thursday,Friday,Saturday,Sunday", "schoolYearStart", "schoolYearEnd", "disable" );


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
###################################

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
###################################
sub Undefine {
    my $hash = shift;
    RemoveInternalTimer($hash);
    DevIo_CloseDev($hash);
    return;
}
###################################
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
###################################
sub Set {
    my $hash = shift;
    my $name = shift;
    my $cmd  = shift // return qq (Set $name needs at least one argument);
    my $arg  = shift;
    my $val  = shift;

    if ( $cmd eq 'password' ) {

        my $err = StorePassword( $hash, $arg );
        if ( !IsDisabled($name) && defined( ReadPassword($hash) ) ) {
            my $next = int( gettimeofday() ) + 1;
            InternalTimer( $next, 'FHEM::Webuntis::wuTimer', $hash, 0 );
        }
        return $err;

    }
    return qq (Unknown argument $cmd, choose one of password);
}
###################################
sub Get {
    my $hash = shift;
    my $name = shift;
    my $cmd  = shift // return "get $name needs at least one argument";

    if ( !ReadPassword($hash) ) {
         return qq(set password first);
    }

    delete $hash->{helper}{cmdQueue};

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
    return qq(Unknown argument $cmd, choose one of timetable:noArg classes:noArg retrieveClasses:noArg schoolYear:noArg);
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
        Log3 $name, LOG_ERROR, "[$name] $err" ;
        readingsSingleUpdate( $hash, "state", "Error: ".$err, 1 );
        delete $hash->{helper}{cmdQueue};
        return;
    }
    $data = latin1ToUtf8($data);
    Log3( $name, LOG_RECEIVE, "getSchoolYear received $data");
    my $json = safe_decode_json( $hash, $data );
    if (!$json) {
        Log3 $name, LOG_ERROR, "[$name] No JSON received for SchoolYear" ;
        readingsSingleUpdate( $hash, "state", "Error: No JSON for SchoolYear", 1 );
        delete $hash->{helper}{cmdQueue};
        return;
    }
    if ( $json->{error} ) {
        Log3 $name, LOG_ERROR, "[$name] $json->{error}{message}" ;
        readingsSingleUpdate( $hash, "state", "Error: ".$json->{error}{message}, 1 );
        delete $hash->{helper}{cmdQueue};
        return;
    }

    my @years = @{ $json->{result} };
    # Find current school year (where today is between startDate and endDate)
    my ($s, $mi, $h, $d, $m, $y) = localtime();
    my $today = sprintf( "%.4d%.2d%.2d", $y + 1900, $m + 1, $d );
    my ($currentStart, $currentEnd, $currentName);
    my $currentId;
    foreach my $year (@years) {
        if ($today ge $year->{startDate} && $today le $year->{endDate}) {
            $currentStart = $year->{startDate};
            $currentEnd = $year->{endDate};
            $currentName = $year->{name};
            $currentId = $year->{id};
            Log3 $name, LOG_DEBUG, "[$name] Current school year found: $currentName ($currentStart to $currentEnd)" ;
            Log3 $name, LOG_DEBUG, "[$name] Current Year Data: ".Dumper($year) ;
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
            return;
        }
        if ( $attr eq 'disable' ) {
            if ( $aVal == 1 ) {
                RemoveInternalTimer($hash);
                DevIo_CloseDev($hash);
                readingsSingleUpdate( $hash, "state", "inactive", 1 );
                $hash->{helper}{DISABLED} = 1;
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
        if ( $attr eq 'schoolYearStart' ) {
            if ( $aVal !~ /^\d{4}\-\d{2}\-\d{2}$/ ) {
                return qq (Attribute schoolYearStart for $name has to be in format YYYY-MM-DD);
            }
        }
        if ( $attr eq 'schoolYearEnd' ) {
            if ( $aVal !~ /^\d{4}\-\d{2}\-\d{2}$/ ) {
                return qq (Attribute schoolYearEnd for $name has to be in format YYYY-MM-DD);
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
    RemoveInternalTimer($hash);
    getTimeTable($hash);
    Log3 $name, LOG_RECEIVE, qq([$name]: Starting Timer);
    my $next = int( gettimeofday() ) + AttrNum( $name, 'interval', 3600 );
    InternalTimer( $next, 'FHEM::Webuntis::wuTimer', $hash, 0 );
    return;
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

    my ( $err, $data ) = HttpUtils_NonblockingGet($param);

}


sub parseLogin {

    my ( $param, $err, $data ) = @_;
    my $hash    = $param->{hash};
    my $name    = $hash->{NAME};
    my $header  = $param->{httpheader};
    my $cookies = getCookies( $hash, $header );

    my $json = safe_decode_json( $hash, $data );
    Log3( $name, LOG_RECEIVE, "login received $data");
    if (!$json) {
        Log3 $name, LOG_ERROR, "[$name] No JSON after Login" ;
        readingsSingleUpdate( $hash, "state", "Error: No JSON after Login", 1 );
        delete $hash->{helper}{cmdQueue};
        return;
    } elsif ( $json->{error} ) {
        Log3( $name, LOG_ERROR, "[$name] $json->{error}{message}" );
        readingsSingleUpdate( $hash, "state", "Error: ".$json->{error}{message}, 1 );
        delete $hash->{helper}{cmdQueue};
        return;
    } else {
		
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
    my $target_time = timelocal($s, $mi, $h, $d-$startDayDelta, $m, $y);
    ($s, $mi, $h, $d, $m, $y) = localtime($target_time);
    my $startdate = sprintf( "%.4d%.2d%.2d", $y + 1900, $m + 1, $d );

    ( $s, $mi, $h, $d, $m, $y ) = localtime( ( time + AttrNum( $name, 'DaysTimetable', 7 ) * 24 * 60 * 60 ) );
    my $enddate = sprintf( "%.4d%.2d%.2d", $y + 1900, $m + 1, $d );

    # Limit to school year boundaries if set
    my $schoolYearStart = ReadingsVal($name, 'schoolYearStart', '');
    my $schoolYearEnd   = ReadingsVal($name, 'schoolYearEnd', '');
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
        Log3 $name, LOG_ERROR, "[$name] $err" ;
        readingsSingleUpdate( $hash, "state", "Error: ".$err, 1 );
        delete $hash->{helper}{cmdQueue};
        return;
    }
    $data = latin1ToUtf8($data);
    Log3( $name, LOG_RECEIVE, "getClass received $data");
    my $json = safe_decode_json( $hash, $data );
    if (!$json) {
        Log3 $name, LOG_ERROR, "[$name] No JSON received for Class" ;
        readingsSingleUpdate( $hash, "state", "Error: No JSON for Class", 1 );
        delete $hash->{helper}{cmdQueue};
        return;
    }
    if ( $json->{error} ) {
        Log3 $name, LOG_ERROR, "[$name] $json->{error}{message}" ;
        readingsSingleUpdate( $hash, "state", "Error: ".$json->{error}{message}, 1 );
        delete $hash->{helper}{cmdQueue};
        return;
    }

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
					$html .= $className;
				}
				else
				{
					$html .= $d->{$f};
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

sub parseTT {
    my ( $param, $err, $data ) = @_;
    my $hash = $param->{hash};
    my $name = $hash->{NAME};

    CommandDeleteReading( undef, "$name e_.*" );

    if ($err) {
        Log3 $name, LOG_ERROR, "[$name] $err" ;
        readingsSingleUpdate( $hash, "state", "Error: ".$err, 1 );
        delete $hash->{helper}{cmdQueue};
        return;
    }
    $data = latin1ToUtf8($data);
    Log3( $name, LOG_RECEIVE, "getTT received $data");
    my $json = safe_decode_json( $hash, $data );
    if (!$json) {
        Log3 $name, LOG_ERROR, "[$name] No JSON received for Timetable" ;
        readingsSingleUpdate( $hash, "state", "Error: No JSON for TT", 1 );
        delete $hash->{helper}{cmdQueue};
        return;
    }
    if ( $json->{error} ) {
        Log3 $name, LOG_ERROR, "[$name] $json->{error}{message}" ;
        readingsSingleUpdate( $hash, "state", "Error: ".$json->{error}{message}, 1 );
        delete $hash->{helper}{cmdQueue};
        return;
    }

    #Log3 ($name, LOG_ERROR, Dumper(${$json->{result}}[0]));
    my @dat = @{ $json->{result} };

    my @sorted =
      sort { $a->{date} <=> $b->{date} or ($a->{code}//=$EMPTY) cmp ($b->{code}//=$EMPTY) or $a->{startTime} <=> $b->{startTime}} @dat;

    Log3 $name, LOG_RECEIVE, Dumper(@sorted) ;

    $hash->{helper}{tt} = \@sorted;

    my ( $s, $mi, $h, $d, $m, $y ) = localtime();
    my $today = sprintf( "%.4d%.2d%.2d", $y + 1900, $m + 1, $d );
#    ( $s, $mi, $h, $d, $m, $y ) = localtime( ( time + 24 * 60 * 60 ) );
	( $s, $mi, $h, $d, $m, $y ) = localtime( ( time + AttrNum( $name, 'DaysTimetable', 7 ) * 24 * 60 * 60 ) );
    my $tomorrow = sprintf( "%.4d%.2d%.2d", $y + 1900, $m + 1, $d );



    my $html = "<html><table>";
    my @exceptions = split( $COMMA, AttrVal( $name, "exceptionIndicator", $EMPTY ) );
	my @exSu = split( $COMMA, AttrVal( $name, "excludeSubjects", $EMPTY ) );
    my ( $a, $exceptionFilter ) = ::parseParams( AttrVal( $name, "exceptionFilter", $EMPTY ) );
    ##my %exceptionFilter = (lstext=>"2.HJ");
    my $exCnt = 0;
    my $rToday = "";
    my $rTomorrow = "";
	my $lastE;
	my $htmlRow = "";
    foreach my $t (@sorted) {
        my $exc;
		# try to compare with previous / we have a matching item
		my $old =$EMPTY;
		my $new =$EMPTY;
		if (defined ($lastE->{date})
			and $lastE->{date} eq $t->{date} 
			and $lastE->{endTime} eq $t->{startTime}
		)
		{	if ($lastE->{lstype}) {$old .= $lastE->{lstype}};
			if ($lastE->{code}) {$old .= $lastE->{code}};
			if ($lastE->{info}) {$old .= $lastE->{info}};
			if ($lastE->{substText}) {$old .= $lastE->{substText}};
			if ($lastE->{lstext}) {$old .= $lastE->{lstext}};
			if ($lastE->{activityType}) {$old .= $lastE->{activityType}};
			if ($t->{lstype}) {$new .= $t->{lstype}};
			if ($t->{code}) {$new .= $t->{code}};
			if ($t->{info}) {$new .= $t->{info}};
			if ($t->{substText}) {$new .= $t->{substText}};
			if ($t->{lstext}) {$new .= $t->{lstext}};
			if ($t->{activityType}) {$new .= $t->{activityType}};
		}
		if ($old eq $new and $old ne $EMPTY){
				$t->{startTime} = $lastE->{startTime};
				$exc = 1;
		}
		else {
			$html .= $htmlRow;
			foreach my $e (@exceptions) {
				if ( $t->{$e} ) {
					if ( $exceptionFilter->{$e} && $t->{$e} =~ /$exceptionFilter->{$e}/ ) {
						next;
					}
					if ($t->{su}[0]{name} && grep(/$t->{su}[0]{name}/,@exSu)) {
						next;
					}
					$exc = 1;
					$exCnt++;
					$lastE = $t;
					last;
				}
			}
		}
        my $rn = ::makeReadingName( "e_" . sprintf( "%02d", $exCnt ) );
        my $rv = $EMPTY;

        $htmlRow = "<tr>";
        my @fields = ( "date", "startTime", "endTime", "lstype", "code", "info", "substText", "lstext", "activityType", "ro", "su", "te" );
        my @ofields = ( "ro", "su", "te" );
        foreach my $f (@fields) {
            $htmlRow .= "<td>";
            if ( $t->{$f} ) {
                if ( any { /^$f$/xsm } @ofields ) {
                    if ( $t->{$f}[0]{longname} ) {
                        $htmlRow .= $t->{$f}[0]{longname};
                        $rv   .= $f.":longname=\"".$t->{$f}[0]{longname}."\"";
                    }
                    $htmlRow .= "</td><td>";
                    $rv   .= $SPACE;
                    if ( $t->{$f}[0]{name} ) {
                        $html .= $t->{$f}[0]{name};
                        $rv   .= $f.":name=\"".$t->{$f}[0]{name}."\"";
                    }

                }
				## if we have an exception filter (ie 1.HJ) then we also don't want this value in the reading
                elsif ( !($exceptionFilter->{$f} && $t->{$f} =~ /$exceptionFilter->{$f}/ )) {
                    $htmlRow .= $t->{$f};
                    $rv   .= $f."=\"".$t->{$f}."\"";
                }
                $htmlRow .= "</td>";
                $rv   .= $SPACE;
            }
        }
        $htmlRow .= "</tr>";
		$html .= $htmlRow;
        if ($exc) {
            readingsSingleUpdate( $hash, $rn, $rv, 1 );
            if ($t->{date} eq $today) {
                if ($rToday eq $EMPTY) {
                    $rToday .= $rn;    
                }
                else {
                    $rToday .= $COMMA.$rn;
                }
            }
            if ($t->{date} eq $tomorrow) {
                if ($rTomorrow eq $EMPTY) {
                    $rTomorrow .= $rn;    
                }
                else {
                    $rTomorrow .= $COMMA.$rn;
                }
            }

        }
    }
    $html .= "</table></html>";

    #Log3 $name, LOG_ERROR, $html;
    $hash->{helper}{timetable} = $html;
    readingsSingleUpdate( $hash, "exceptionToday", join($COMMA,uniq(split($COMMA,$rToday))), 1 );
    readingsSingleUpdate( $hash, "exceptionTomorrow", join($COMMA,uniq(split($COMMA,$rTomorrow))), 1 );
    readingsSingleUpdate( $hash, "exceptionCount", $exCnt, 1 );
    readingsSingleUpdate( $hash, "state", "processing done", 1 );
	
	### Export timetable into iCal - file ### Sailor ###
	exportTT2iCal($hash);
    return;
}

sub simpleTable {
    my $name = shift;
    my $pattern = shift;
    my $cnt = ReadingsNum($name, "exceptionCount",0);
    my $html = "<html><body><b>".AttrVal($name,"alias",$name)."</b><table>";

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
                if (length($val) >= 8) {
					my $j = substr($val, 0, 4);
					my $m = substr($val, 4, 2);
					my $d = substr($val, 6, 2);
					$formatted = "$d.$m.$j";
				} else {
					$formatted = '';  # or keep original $val, or log a warning
					Log3 ($name, LOG_ERROR, "SimpleTable: Date string too short: $val");
				}
            }
            elsif ($f =~ /Time/) {
				if (length($val) >= 4) {
					my $ho = substr($val, 0, 2);
					my $m  = substr($val, 2, 2);
					$formatted = "$ho:$m";
				}
				elsif (length($val) == 3) {
					my $ho = "0" . substr($val, 0, 1);
					my $m  = substr($val, 1, 2);
					$formatted = "$ho:$m";
				}
				else {
					$formatted = '';  # or keep $val
					Log3 ($name, LOG_ERROR, "SimpleTable: Time string too short: $val");
				}
			}
            elsif ($f eq "code" and $val ne 'default') {
                        $formatted = $codeMap{$val};
			}
            else {
                $formatted = $val;
            }
			if ($formatted) {
				$html .= "<td>$formatted</td>";
			}
        }
        $html .= "</tr>";
    }
    $html .= "</table></body></html>";

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

### To export entire time table into iCal from @Sailor
sub exportTT2iCal {
    my $hash          = shift;
    my $name          = $hash->{NAME};
	my $iCalPath      = AttrVal($name, "iCalPath", "");

	### Check ehether the Attribute iCalPath has been provided otherwise skip export
	if ($iCalPath ne "") {

		my $iCalFileName;
		my $iCalFileContent;
		my @jsonTimeTable = $hash->{helper}{tt};
		my $user          = AttrVal($name, "user"    , "NA");

		### Get current timestamp
		my ($sec,$min,$hour,$mday,$mon,$year,$wday,$yday,$isdst) = localtime();
		$year = $year + 1900;
		$mon++;

		####START##### Transform json-Timetable in ical Timetable #####START####
		$iCalFileContent = "BEGIN:VCALENDAR\nVERSION:2.0\n-//fhem Home Automation//NONSGML 69_Webuntis//EN\nMETHOD:PUBLISH\n\n";
		foreach my $TimeTableArray ( @jsonTimeTable ) {

			### Log Entry for debugging purposes
			Log3 $name, 5, $name. " : Webuntis_exportTT2iCal - TimeTableArray           : " . Dumper($TimeTableArray);
			Log3 $name, 5, $name. " : Webuntis_exportTT2iCal====================================================";
			
			foreach my $TTHashcontent (@$TimeTableArray) {
				Log3 $name, 5, $name. " : Webuntis_exportTT2iCal - Progressing TT item      : #" . $TTHashcontent->{id};

				my $TTClass    = Encode::decode( 'iso-8859-1', $TTHashcontent->{kl}[0]{longname}) || 'NN ';
				my $TTSubject  = Encode::decode( 'iso-8859-1', $TTHashcontent->{su}[0]{longname}) || 'NN ';
				my $TTTeacher  = Encode::decode( 'iso-8859-1', $TTHashcontent->{te}[0]{longname}) || 'NN ';
				my $TTLocation = Encode::decode( 'iso-8859-1', $TTHashcontent->{ro}[0]{longname}) || 'NN ';
	
				my $CalSubject = $TTClass . " " . $TTSubject . " " . $TTTeacher;
				my $CalInfo    = "Klasse: " . $TTClass . "\\n" . "Unterricht: " . $TTSubject . "\\n" . "Ort: " . $TTLocation . "\\n" . "Lehrkraft: " . $TTTeacher;

				$iCalFileContent .= "BEGIN:VEVENT\n";
				$iCalFileContent .= "CLASS:PUBLIC\n";
				$iCalFileContent .= "STATUS:CONFIRMED\n";
				$iCalFileContent .= "TRANSP:TRANSPARENT\n";
				$iCalFileContent .= "CATEGORIES:EDUCATION\n";
				$iCalFileContent .= "URL:"                        . AttrVal($name, "server", ""  ) . "\n";
				$iCalFileContent .= "UID:"                        . $TTHashcontent->{id} . "\n";
				$iCalFileContent .= "LOCATION:"                   . $TTLocation . "\n";
				$iCalFileContent .= "DTSTART;TZID=Europe/Berlin:" . $TTHashcontent->{date} . "T" . sprintf('%04d',$TTHashcontent->{startTime}) . "00\n";
				$iCalFileContent .= "DTEND;TZID=Europe/Berlin:"   . $TTHashcontent->{date} . "T" . sprintf('%04d',$TTHashcontent->{endTime})   . "00\n";
				$iCalFileContent .= "DTSTAMP;TZID=Europe/Berlin:" . sprintf('%04d', $year) . sprintf('%02d', $mon) . sprintf('%02d', $mday) . "T" . sprintf('%02d', $hour) . sprintf('%02d', $min) . sprintf('%02d', $sec)  ."\n";
				$iCalFileContent .= "SUMMARY:"                    . $CalSubject . "\n";
				$iCalFileContent .= "DESCRIPTION:"                . $CalInfo . "\n";
				$iCalFileContent .= "END:VEVENT\n\n";
				Log3 $name, 5, $name. " : Webuntis_exportTT2iCal_____________________________________________________";
			}
		}
		$iCalFileContent .= "END:VCALENDAR";
		#####END###### Transform json-Timetable in ical Timetable ######END#####


		### Get current working directory
		my $cwd = getcwd();
		my $IcalFileDir;

		### Log Entry for debugging purposes
		Log3 $name, 5, $name. " : Webuntis_exportTT2iCal - working directory        : " . $cwd;

		### If the path is given as UNIX file system format
		if ($cwd =~ /\//) {
			### Log Entry for debugging purposes
			Log3 $name, 5, $name. " : Webuntis_exportTT2iCal - file system format     : LINUX";

			### Find out whether it is an absolute path or an relative one (leading "/")
			if ($iCalPath =~ /^\//) {
			
				$iCalFileName = $iCalPath;
			}
			else {
				$iCalFileName = $cwd . "/" . $iCalPath;						
			}

			### Check whether the last "/" at the end of the path has been given otherwise add it an create complete path
			if ($iCalPath =~ /\/\z/) {
				### Save directory
				$IcalFileDir = $iCalFileName;
				
				### Create complete datapath

				$iCalFileName .=       "untis_TT_" . $user . ".ics";
			}
			else {
				### Save directory
				$IcalFileDir = $iCalFileName . "/";
				
				### Create complete datapath
				$iCalFileName .= "/" . "untis_TT_" . $user . ".ics";
			}
		}

		### If the path is given as Windows file system format
		if ($iCalPath =~ /\\/) {
			### Log Entry for debugging purposes
			Log3 $name, 5, $name. " : Webuntis_exportTT2iCal - file system format       : WINDOWS";

			### Find out whether it is an absolute path or an relative one (containing ":\")
			if ($iCalPath != /^.:\//) {
				$iCalFileName = $cwd . $iCalPath;
			}
			else {
				$iCalFileName = $iCalPath;						
			}

			### Check whether the last "/" at the end of the path has been given otherwise add it an create complete path
			if ($iCalPath =~ /\\\z/) {
				### Save directory
				$IcalFileDir = $iCalFileName;
				
				### Create full datapath
				$iCalFileName .=       "untis_TT_" . $user . ".ics";;
			}
			else {
				### Save directory
				$IcalFileDir = $iCalFileName . "\\";

				### Create full datapath
				$iCalFileName .= "\\" . "untis_TT_" . $user . ".ics";;
			}
		}

		Log3 $name, 5, $name . " : Webuntis_exportTT2iCal - Saving TT for " . $user . " to  : " . $iCalFileName;
		
		open(FH, '>', $iCalFileName);
		print FH $iCalFileContent;
		close(FH);
	}
	### Skipping export
	else {
		### Log Entry for debugging purposes
		Log3 $name, 4, $name . " : Webuntis_exportTT2iCal - Attribute \"iCalPath\" mot provided - Skipping export.";
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
 </ul>
<a name='WebuntisSet'></a>
        <b>Set</b>
        <ul>
<li><a name='password'></a>usually only needed initially (or if you change your password in the cloud)</li>
 </ul>
<a name='WebuntisAttr'></a>
        <b>Attributes</b>
        <ul>
<li><a name='class'>the class for which timetable data should be retrieved</a></li>
<li><a name='school'>your school</a></li>
<li><a name='server'>something like https://server.webuntis.com</a></li>
<li><a name='user'>your username</a></li>
<li><a name='exceptionIndicator'>Which fields should be populated to create exception readings</a></li>
<li><a name='exceptionFilters'>Which field values should not be considered as an exception</a></li>
<li><a name='excludeSubjects'>Which subjects should be ignored</a></li>
<li><a name='interval'>polling interval in seconds (defaults to 3600)</a></li>
<li><a name='studentID'>used to get the student specific timetable instead of class based. Needs attr <code>timeTableMode</code> to be set to Student</a></li>
<li><a name='timeTableMode'>class: use the class information / id for timetable <br>student: use the studentId to get the student time table.</a></li>
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
<li><a name='timetable'>reads the timetable data from Webuntis</a></li>
<li><a name='retrieveClasses'>reads theclasses from Webuntis</a></li>
<li><a name='Classes'>display retrieved Classes</a></li>
 </ul>
<a name='WebuntisSet'></a>
        <b>Set</b>
        <ul>
<li><a name='password'>usually only needed initially (or if you change your password in the cloud)</a></li>
 </ul>
<a name='WebuntisAttr'></a>
        <b>Attributes</b>
        <ul>
<li><a name='class'>the class for which timetable data should be retrieved</a></li>
<li><a name='school'>your school</a></li>
<li><a name='server'>something like https://server.webuntis.com</a></li>
<li><a name='user'>your username</a></li>
<li><a name='exceptionIndicator'>Which fields should be populated to create exception readings</a></li>
<li><a name='exceptionFilters'>Which field values should not be considered as an exception</a></li>
<li><a name='excludeSubjects'>Which subjects should be ignored</a></li>
<li><a name='interval'>polling interval in seconds (defaults to 3600)</a></li>
<li><a name='iCalPath'>path to write a iCal to - must exist and be writeable by fhem. gets written after getTimeTable </a></li>
<li><a name='studentID'>used to get the student specific timetable instead of class based. Needs attr <code>timeTableMode</code> to be set to Student</a></li>
<li><a name='timeTableMode'>class: use the class information / id for timetable <br>student: use the studentId to get the student time table.</a></li>
            </ul>
   </ul>
</div>
=end html_DE