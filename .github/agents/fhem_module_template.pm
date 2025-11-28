# Minimal FHEM module skeleton illustrating best practices, documentation and modularity.
# Use this as a template when creating or refactoring modules.
#
# NOTE: This file is a template and not intended to be installed as-is.
#       Replace <ModuleName> and customize logic per your module.

package main;

use strict;
use warnings;
use JSON::XS;       # lightweight, fast JSON
use LWP::UserAgent; # HTTP fetching
use IO::Socket::SSL;
use Time::HiRes qw(gettimeofday tv_interval);

# Module registration for FHEM
sub <ModuleName>_Initialize {
  my ($hash) = @_;
  # Command handling conventions: Define, Set, Get, Notify
  $hash->{DefFn}    = "<ModuleName>_Define";
  $hash->{UndefFn}  = "<ModuleName>_Undef";
  $hash->{SetFn}    = "<ModuleName>_Set";
  $hash->{GetFn}    = "<ModuleName>_Get";
  $hash->{AttrList} = "disable:0,1 interval loglevel";
  # Provide a short description used by FHEM
  $hash->{Readings}{state}{};
}

# Example Define function
sub <ModuleName>_Define {
  my ($hash, $def) = @_;
  my @args = split("[ \t]+", $def);
  # syntax: define <name> <ModuleName> <url> <user> <pass>
  return "Usage: define <name> <ModuleName> <url> <user> <pass>" unless @args >= 5;

  my $name = $args[0];
  my $url  = $args[2];
  my $user = $args[3];
  my $pass = $args[4];

  $hash->{NAME} = $name;
  $hash->{URL}  = $url;
  $hash->{USER} = $user;
  $hash->{PASS} = $pass;

  # default attributes and state
  $hash->{STATE} = "defined";
  readingsSingleUpdate($hash, "state", "defined", 1);

  # register timer for polling if needed
  InternalTimer(gettimeofday() + 1, "<ModuleName>_Poll", $hash, 0);

  return undef;
}

sub <ModuleName>_Undef {
  my ($hash, $name) = @_;
  # cleanup timers, resources
  RemoveInternalTimer($hash);
  return undef;
}

# Poll function (internal timer)
sub <ModuleName>_Poll {
  my ($hash) = @_;
  eval {
    my $res = <ModuleName>_fetch_and_parse($hash);
    if ($res) {
      readingsSingleUpdate($hash, "state", "ok", 1);
      # update other readings as needed
    } else {
      readingsSingleUpdate($hash, "state", "error", 1);
    }
  };
  if ($@) {
    Log3($hash, 3, "<ModuleName>_Poll: caught error: $@");
    readingsSingleUpdate($hash, "state", "error", 1);
  }
  # reschedule based on attr interval
  my $interval = AttrVal($hash->{NAME}, "interval", 300);
  InternalTimer(gettimeofday() + $interval, "<ModuleName>_Poll", $hash, 0);
}

# Example Set function
sub <ModuleName>_Set {
  my ($hash, $name, $cmd, @args) = @_;
  if ($cmd eq "trigger") {
    # run an immediate poll
    <ModuleName>_Poll($hash);
    return undef;
  }
  return "Unknown argument $cmd, choose one of trigger";
}

# Example Get function
sub <ModuleName>_Get {
  my ($hash, $name, $cmd, @args) = @_;
  if ($cmd eq "status") {
    return "state: " . ReadingsVal($name, "state", "undefined");
  }
  return "Unknown argument $cmd, choose one of status";
}

# Helper: fetch data with timeout, retry and minimal backoff
sub <ModuleName>_fetch_and_parse {
  my ($hash) = @_;

  my $url  = $hash->{URL};
  my $user = $hash->{USER};
  my $pass = $hash->{PASS};

  my $ua = LWP::UserAgent->new(
    timeout => 10,
    agent   => "FHEM-<ModuleName>/0.1",
    ssl_opts => { verify_hostname => 1 },
  );

  my $max_retries = 2;
  my $attempt = 0;
  my $resp;

  while ($attempt <= $max_retries) {
    $attempt++;
    $resp = $ua->get($url);
    if ($resp->is_success) {
      last;
    } else {
      Log3($hash, 4, "<ModuleName>_fetch: attempt $attempt failed: " . $resp->status_line);
      sleep(1 * $attempt); # simple linear backoff
    }
  }

  unless ($resp && $resp->is_success) {
    Log3($hash, 3, "<ModuleName>_fetch: failed after $attempt attempts");
    return undef;
  }

  my $content = $resp->decoded_content;
  # parse JSON safely
  my $data;
  eval { $data = JSON::XS->new->utf8(0)->decode($content); };
  if ($@) {
    Log3($hash, 3, "<ModuleName>_fetch: JSON decode error: $@");
    return undef;
  }

  # Example: update a reading from parsed data
  if (ref $data eq 'HASH' && exists $data->{status}) {
    readingsSingleUpdate($hash, "api_status", $data->{status}, 1);
  }

  return 1;
}

1;

=pod

=head1 NAME

<ModuleName> - FHEM integration template

=head1 SYNOPSIS

define <name> <ModuleName> <url> <user> <pass>
set <name> trigger
get <name> status

=head1 DESCRIPTION

This file is a template that demonstrates how to write FHEM modules with:
- Clear help
- Robust fetching with timeouts and retries
- JSON parsing with error handling
- Readings updates and InternalTimer usage

=head1 AUTHOR

Template by Copilot FHEM Perl Expert

=cut