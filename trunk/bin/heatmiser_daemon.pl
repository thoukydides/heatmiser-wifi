#!/usr/bin/perl

# This is a daemon for logging temperature and central heating usage data from
# the iPhone interface of Heatmiser's range of Wi-Fi enabled thermostats to a
# database for later analysis and charting.
#
# Ensure that user that runs this script is able to create
# '/var/run/heatmiser_daemon.pl.pid'. On most systems this probably means that
# it needs to be run as root.

# Copyright © 2011, 2012 Alexander Thoukydides
#
# This file is part of the Heatmiser Wi-Fi project.
# <http://code.google.com/p/heatmiser-wifi/>
#
# Heatmiser Wi-Fi is free software: you can redistribute it and/or modify it
# under the terms of the GNU General Public License as published by the Free
# Software Foundation, either version 3 of the License, or (at your option)
# any later version.
#
# Heatmiser Wi-Fi is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
# or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License
# along with Heatmiser Wi-Fi. If not, see <http://www.gnu.org/licenses/>.


# Catch errors quickly
use strict;
use warnings;

# Allow use of modules in the same directory
use Cwd 'abs_path';
use File::Basename;
use lib dirname(abs_path $0);

# Useful libraries
use Data::Dumper;
use Getopt::Std;
use Proc::Daemon;
use Proc::PID::File;
use heatmiser_config;
use heatmiser_db;
use heatmiser_wifi;

# Command line options
my ($prog) = $0 =~ /([^\\\/]+$)/;
sub VERSION_MESSAGE { print "Heatmiser Wi-Fi Thermostat Daemon v1\n"; }
sub HELP_MESSAGE { print "Usage: $prog [-v] [-h <host>] [-p <pin>] [-i <logseconds>] [-s <dbsource>] [-u <dbuser>] [-a <dbpassword>] [-l <logfile>]\n"; }
$Getopt::Std::STANDARD_HELP_VERSION = 1;
our ($opt_v, $opt_h, $opt_p, $opt_i, $opt_s, $opt_u, $opt_a, $opt_l);
getopts('vh:p:i:s:u:a:l:');
heatmiser_config::set(verbose => $opt_v, host => [h => $opt_h],
                      pin => [p => $opt_p], logseconds => [i => $opt_l],
                      dbsource => [s => $opt_s], dbuser => [u => $opt_u],
                      dbpassword => [a => $opt_a], logfile => [l => $opt_l]);

# Start as a daemon (current script exits at this point)
my $logfile = heatmiser_config::get_item('logfile');
Proc::Daemon::Init({child_STDERR => "+>>$logfile"});

# Exit if already running
die "Daemon already running\n" if Proc::PID::File->running();

# Redirect all output to the log file and disable buffering
open(STDOUT, '>&STDERR') or die "Failed to re-open STDOUT to STDERR: $!\n";
$| = 1, select $_ for select STDOUT;
print ">>>> $prog started >>>>\n";

# Connect to the database
my $db = new heatmiser_db(heatmiser_config::get(qw(dbsource dbuser dbpassword host)));

# Prepare each thermostat being logged
my %thermostats;
foreach my $thermostat (@{heatmiser_config::get_item('host')})
{
    $thermostats{$thermostat} =
    {
        # Instantiate a object for connecting to this thermostat
        hm => new heatmiser_wifi(host => $thermostat,
                                 heatmiser_config::get(qw(pin))),

        # Initial state for this thermostat for tracking interesting events
        last_heat     => { cause => '', state => -1, target => -1 },
        last_hotwater => { cause => '', state => 0 }
    };
}

# Loop until a signal is caught
my $signal;
sub quit { $signal = shift; print "Caught $signal: exiting gracefully\n"; }
$SIG{HUP}  = sub { quit('SIGHUP'); };
$SIG{INT}  = sub { quit('SIGINT'); };
$SIG{QUIT}  = sub { quit('SIGQUIT'); };
$SIG{TERM}  = sub { quit('SIGTERM'); };
while (not $signal)
{
    # Read and log the status for each thermostat
    my $last_time;
    while (my ($thermostat, $self) = each %thermostats)
    {
        # Trap errors while reading the status and updating the database
        eval
        {
            # Read current status and disconnect so other clients can connect
            my @dcb = $self->{hm}->read_dcb();
            $self->{hm}->close();

            # Decode the status
            my $status = $self->{hm}->dcb_to_status(@dcb);
            my ($comfort, $next_comfort) = $self->{hm}->lookup_comfort($status);
            my $timer = $self->{hm}->lookup_timer($status);
            $last_time = $status->{time} unless defined $last_time;

            # Determine the actions and their causes
            my ($heat_target, $heat_cause) =
                action_heat($status, $comfort, $next_comfort);
            my ($hotwater_state, $hotwater_cause) =
                action_hotwater($status, $timer);

            # Update the stored configuration
            log_config($db, $thermostat, $status);

            # Log the current details
            log_status($db, $thermostat, $status,
                       $comfort, $heat_target, $heat_cause,
                       $timer, $hotwater_state, $hotwater_cause);

            # Log interesting events
            log_event_heat($db, $thermostat, $status,
                           $heat_target, $heat_cause,
                           $self->{last_heat});
            log_event_hotwater($db, $thermostat, $status,
                               $hotwater_state, $hotwater_cause,
                               $self->{last_hotwater});

        };
        print "Error while logging '$thermostat': $@\n" if $@;
    }

    # Pause before reading the status again
    my $sleep = heatmiser_config::get_item('logseconds');
    if ((24 * 60 * 60) % $sleep == 0
        and defined $last_time and $last_time =~ /(\d\d):(\d\d):(\d\d)$/)
    {
        # Attempt to align to a multiple of the log interval
        my $correction = (($1 * 60 + $2) * 60 + $3) % $sleep;
        $correction -= $sleep if $sleep / 2 < $correction;
        $sleep -= $correction;
    }
    print "Sleeping for $sleep seconds\n"
        if heatmiser_config::get_item('verbose');
    sleep($sleep);
}

# That's all folks!
print "<<< $prog stopped ($signal) <<<<\n";
exit;


# Determine the target temperature and its cause
sub action_heat
{
    my ($status, $comfort, $next_comfort) = @_;

    # Consider influences in decreasing order of importance
    my ($target, $cause);
    unless (defined $status->{heating})
    {
        # Thermostat does not control heating
        $target = 0;
        $cause = '';
    }
    elsif (not $status->{enabled})
    {
        # Thermostat switched off
        $target = 0;
        $cause = 'off';
    }
    elsif ($status->{runmode} eq 'frost')
    {
        # Frost protection mode (includes holiday)
        $target = $status->{frostprotect}->{enabled}
                  ? $status->{frostprotect}->{target} : 0;
        $cause = $status->{holiday}->{enabled} ? 'holiday' : 'away';
    }
    else
    {
        # Normal heating mode (includes manual adjustment and comfort level)
        $target = $status->{heating}->{target};
        $cause = $status->{heating}->{hold}
                 ? 'hold'
                 : ($status->{heating}->{target} == $comfort
                    ? 'comfortlevel'
                    : (($status->{heating}->{target} == $next_comfort
                        and $comfort < $next_comfort)
                       ? 'optimumstart' : 'manual'));
    }

    # Return the result
    return ($target, $cause);
}

# Determine the hot water state and its cause
sub action_hotwater
{
    my ($status, $timer) = @_;

    # Consider influences in decreasing order of importance
    my ($state, $cause);
    unless (defined $status->{hotwater})
    {
        # Thermostat does not control hot water
        $state = 0;
        $cause = '';
    }
    elsif (not $status->{enabled})
    {
        # Thermostat switched off
        $state = 0;
        $cause = 'off';
    }
    else
    {
        # Normal control mode (includes manual override)
        $state = $status->{hotwater}->{on};
        $cause = $status->{hotwater}->{on} == $timer
                 ? 'timer' : 'override';
    }

    # Return the result
    return ($state, $cause);
}

# Update the stored the configuration
sub log_config
{
    my ($db, $thermostat, $status) = @_;

    # Store the main configuration of the thermostat
    $db->settings_update($thermostat,
                         host     => $thermostat,
                         vendor   => $status->{product}->{vendor},
                         version  => $status->{product}->{version},
                         model    => $status->{product}->{model},
                         mode     => $status->{enabled}
                                     ? ($status->{runmode} || 'on') : 'off',
                         units    => $status->{config}->{units},
                         holiday  => $status->{holiday}->{enabled}
                                     ? $status->{holiday}->{time} : '',
                         progmode => $status->{config}->{progmode});

    # Update the programmed comfort levels and hot water timers
    $db->comfort_update($thermostat, $status->{comfort});
    $db->timer_update($thermostat, $status->{timer});
}

# Log the current status and measurements
sub log_status
{
    my ($db, $thermostat, $status,
        $comfort, $heat_target, $heat_cause,
        $timer, $hotwater_state, $hotwater_cause) = @_;

    # Store the current status
    $db->log_insert($thermostat,
                    time    => $status->{time},
                    air     => $status->{temperature}->{internal},
                    target  => $heat_target,
                    comfort => $comfort);

    # Add a log file entry if enabled
    if (heatmiser_config::get_item('verbose'))
    {
        my $u = $status->{config}->{units};
        printf "%s: %s Air=%.1f$u Target=%i$u Cause=%s Comfort=%i$u Heating=%s HotWater=%s Cause=%s Timer=%s\n",
               $thermostat,
               $status->{time},
               $status->{temperature}->{internal},
               $heat_target,
               $heat_cause,
               $comfort,
               $status->{heating}->{on} ? 'ON' : 'OFF',
               $hotwater_state ? 'ON' : 'OFF',
               $hotwater_cause,
               $timer ? 'ON' : 'OFF';
    }
}

# Log interesting heating events
sub log_event_heat
{
    my ($db, $thermostat, $status, $target, $cause, $last) = @_;

    # Only record changes of state (and initial state)
    my $state = $status->{heating}->{on};
    if ($state != $last->{state})
    {
        $db->event_insert($thermostat,
                          time        => $status->{time},
                          class       => 'heating',
                          state       => $state);
    }
    if ($cause ne $last->{cause} or $target != $last->{target})
    {
        $db->event_insert($thermostat,
                          time        => $status->{time},
                          class       => 'target',
                          state       => $cause,
                          temperature => $target);
    }

    # Remember the current state
    $last->{cause} = $cause;
    $last->{state} = $state;
    $last->{target} = $target;
}

# Log interesting hot water events
sub log_event_hotwater
{
    my ($db, $thermostat, $status, $state, $cause, $last) = @_;

    # Only record changes of state (and initial state, if hot water controlled)
    if ($state ne $last->{state} or $cause ne $last->{cause})
    {
        $db->event_insert($thermostat,
                          time        => $status->{time},
                          class       => 'hotwater',
                          state       => $cause,
                          temperature => $state);
    }

    # Remember the current state
    $last->{cause} = $cause;
    $last->{state} = $state;
}
