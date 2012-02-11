#!/usr/bin/perl

# This is a daemon for logging temperature and central heating usage data from
# the iPhone interface of Heatmiser's range of Wi-Fi enabled thermostats to a
# database for later analysis and charting.
#
# Ensure that user that runs this script is able to create
# '/var/run/heatmiser_daemon.pl.pid'. On most systems this probably means that
# it needs to be run as root.

# Copyright © 2011 Alexander Thoukydides
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
my $db = new heatmiser_db(heatmiser_config::get(qw(dbsource dbuser dbpassword)));

# Instantiate an object for connecting to the thermostat
my $heatmiser = new heatmiser_wifi(heatmiser_config::get(qw(host pin)));

# Loop until a signal is caught
my $signal;
sub quit { $signal = shift; print "Caught $signal: exiting gracefully\n"; }
$SIG{HUP}  = sub { quit('SIGHUP'); };
$SIG{INT}  = sub { quit('SIGINT'); };
$SIG{QUIT}  = sub { quit('SIGQUIT'); };
$SIG{TERM}  = sub { quit('SIGTERM'); };
my ($last_heat, $last_heat_cause, $last_target) = (-1, '', -1);
my ($last_hotwater_cause, $last_hotwater_state) = ('', 0);
while (not $signal)
{
    # Trap errors while reading the status and updating the database
    my $status;
    eval
    {
        # Read current status and disconnect to allow other clients to connect
        my @dcb = $heatmiser->read_dcb();
        $heatmiser->close();

        # Decode the status
        $status = $heatmiser->dcb_to_status(@dcb);
        my ($comfort, $next_comfort) = $heatmiser->lookup_comfort($status);
        my ($timer) = $heatmiser->lookup_timer($status);

        # Determine the target temperature and its cause
        my ($heat_target, $heat_cause);
        unless (defined $status->{heating})
        {
            # Thermostat does not control heating
            $heat_target = 0;
            $heat_cause = '';
        }
        elsif (not $status->{enabled})
        {
            # Thermostat switched off
            $heat_target = 0;
            $heat_cause = 'off';
        }
        elsif ($status->{runmode} eq 'frost')
        {
            # Frost protection mode (includes holiday)
            $heat_target = $status->{frostprotect}->{enabled}
                           ? $status->{frostprotect}->{target} : 0;
            $heat_cause = $status->{holiday}->{enabled} ? 'holiday' : 'away';
        }
        else
        {
            # Normal heating mode (includes manual adjustment and comfort level)
            $heat_target = $status->{heating}->{target};
            $heat_cause = $status->{heating}->{hold}
                          ? 'hold'
                          : ($status->{heating}->{target} == $comfort
                             ? 'comfortlevel'
                             : (($status->{heating}->{target} == $next_comfort
                                and $comfort < $next_comfort)
                                ? 'optimumstart' : 'manual'));
        }

        # Determine the hot water state and its cause
        my ($hotwater_state, $hotwater_cause);
        unless (defined $status->{hotwater})
        {
            # Thermostat does not control hot water
            $hotwater_state = 0;
            $hotwater_cause = '';
        }
        elsif (not $status->{enabled})
        {
            # Thermostat switched off
            $hotwater_state = 0;
            $hotwater_cause = 'off';
        }
        else
        {
            # Normal control mode (includes manual override)
            $hotwater_state = $status->{hotwater}->{on};
            $hotwater_cause = $status->{hotwater}->{on} == $timer
                              ? 'timer' : 'override';
        }

        # Update the stored the configuration
        $db->settings_update(host => heatmiser_config::get_item('host'),
                             vendor => $status->{product}->{vendor},
                             version => $status->{product}->{version},
                             model => $status->{product}->{model},
                             mode => $status->{enabled}
                                     ? ($status->{runmode} || 'on') : 'off',
                             units => $status->{config}->{units},
                             holiday => $status->{holiday}->{enabled}
                                        ? $status->{holiday}->{time} : '',
                             progmode => $status->{config}->{progmode});
        $db->comfort_update($status->{comfort});
        $db->timer_update($status->{timer});

        # Log the current details
        $db->log_insert(time => $status->{time},
                        air => $status->{temperature}->{internal},
                        target => $heat_target,
                        comfort => $comfort);
        my $u = $status->{config}->{units};
        printf "%s Air=%.1f$u Target=%i$u Cause=%s Comfort=%i$u Heating=%s HotWater=%s Cause=%s Timer=%s\n",
               $status->{time},
               $status->{temperature}->{internal},
               $heat_target,
               $heat_cause,
               $comfort,
               $status->{heating}->{on} ? 'ON' : 'OFF',
               $hotwater_state ? 'ON' : 'OFF',
               $hotwater_cause,
               $timer ? 'ON' : 'OFF'
                   if heatmiser_config::get_item('verbose');

        # Log interesting events (record current state on first pass)
        if ($status->{heating}->{on} != $last_heat)
        {
            $db->event_insert(time => $status->{time},
                              class => 'heating',
                              state => $status->{heating}->{on});
            $last_heat = $status->{heating}->{on};
        }
        if ($heat_cause ne $last_heat_cause or $heat_target != $last_target)
        {
            $db->event_insert(time => $status->{time},
                              class => 'target',
                              state => $heat_cause,
                              temperature => $heat_target);
            ($last_heat_cause, $last_target) = ($heat_cause, $heat_target);
        }
        if ($hotwater_cause ne $last_hotwater_cause
            or $hotwater_state ne $last_hotwater_state)
        {
            $db->event_insert(time => $status->{time},
                              class => 'hotwater',
                              state => $hotwater_cause,
                              temperature => $hotwater_state);
            ($last_hotwater_cause, $last_hotwater_state) =
                ($hotwater_cause, $hotwater_state);
        }
    };
    print "Error while logging: $@\n" if $@;

    # Pause before reading the status again
    my $sleep = heatmiser_config::get_item('logseconds');
    if ((24 * 60 * 60) % $sleep == 0 and exists $status->{time}
        and $status->{time} =~ /(\d\d):(\d\d):(\d\d)$/)
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
