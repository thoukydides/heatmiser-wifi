#!/usr/bin/perl

# This is a simple script to illustrate use of the Heatmiser Wi-Fi Perl
# library for retrieving weather observations from online services.

# Copyright © 2012 Alexander Thoukydides
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
use Getopt::Std;
use heatmiser_config;
use heatmiser_db;
use heatmiser_weather;

# Command line options
my ($prog) = $0 =~ /([^\\\/]+$)/;
sub VERSION_MESSAGE { print "Heatmiser Wi-Fi Thermostat Weather History CLI\n"; }
sub HELP_MESSAGE { print "Usage: $prog [-w <wservice>] [-k <wkey>] [-g <wlocation>] [-f <wunits>] [-s <dbsource>] [-u <dbuser>] [-a <dbpassword>]\n"; }
$Getopt::Std::STANDARD_HELP_VERSION = 1;
our ($opt_w, $opt_k, $opt_g, $opt_f, $opt_s, $opt_u, $opt_a);
getopts('w:k:g:f:s:u:a:');
heatmiser_config::set(wservice => [w => $opt_w], wkey => [k => $opt_k],
                      wlocation => [g => $opt_g], wunits => [f => $opt_f],
                      dbsource => [s => $opt_s], dbuser => [u => $opt_u],
                      dbpassword => [a => $opt_a]);

# Warn if using the same API key as the daemon when using Weather Underground
my $weather = new heatmiser_weather(heatmiser_config::get(qw(wservice wkey wlocation wunits)));
die "An API key must be explicitly specified using the -k option (preferably different to the one being used for the daemon in order to avoid using up its daily API calls allowance)\n" if heatmiser_config::get_item('wservice') eq 'wunderground' and not defined $opt_k;

# Connect to the database
my $db = new heatmiser_db(heatmiser_config::get(qw(dbsource dbuser dbpassword)));

# Determine the range of dates for which historical data is required
my $thermostat_dates = $db->log_dates();
die "There is no thermostat temperature data in the database\n" unless defined $thermostat_dates->[0];
print "Database currently contains:\n";
printf "    %-30s %s  to  %s\n", 'Thermostat temperature data',
       $thermostat_dates->[0], $thermostat_dates->[1];
my $weather_dates = $db->weather_dates();
my ($history_from, $history_to) = @$thermostat_dates;
if (defined $weather_dates->[0])
{
    # The database already contains some external temperature data
    printf "    %-30s %s  to  %s\n", 'External temperature data',
           $weather_dates->[0], $weather_dates->[1];
    die "Database already contains complete external temperature history\n" if $weather_dates->[0] le $thermostat_dates->[0];
    $history_to = $weather_dates->[0];
}
else
{
    # There is no external temperature data in the database
    print "    No external temperature data\n";
}

# Read the historical temperature data for the selected date range
printf "\n%-34s %s  to  %s\n", 'Retrieving historical data...',
       $history_from, $history_to;
my $history = $weather->historical_temperature($history_from, $history_to);
die "No historical external temperature data within range\n" unless @$history;
printf "    %-30s %s  to  %s\n",
       'Obtained ' . (scalar @$history) . ' observations',
       $history->[0]->[0], $history->[-1]->[0];

# Add the historical data to the database
# (starting with the most recent to allow resumption if interrupted)
print "\nAdding retrieved data to the database...";
foreach my $observation (reverse @$history)
{
    my ($timestamp, $external) = @$observation;
    $db->weather_insert(time => $timestamp, external => $external);
}
print " done\n";

# That's all folks
exit;
