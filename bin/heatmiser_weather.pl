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
use heatmiser_weather;

# Command line options
my ($prog) = $0 =~ /([^\\\/]+$)/;
sub VERSION_MESSAGE { print "Heatmiser Wi-Fi Thermostat Weather CLI\n"; }
sub HELP_MESSAGE { print "Usage: $prog [-w <wservice>] [-k <wkey>] [-g <wlocation>] [-f <wunits>] [-d]\n"; }
$Getopt::Std::STANDARD_HELP_VERSION = 1;
our ($opt_w, $opt_k, $opt_g, $opt_f, $opt_d);
getopts('w:k:g:f:d');
heatmiser_config::set(wservice => [w => $opt_w], wkey => [k => $opt_k],
                      wlocation => [g => $opt_g], wunits => [f => $opt_f],
                      debug => $opt_d);

# Read the most recent weather observation, trapping any error to allow debug
my $weather = new heatmiser_weather(heatmiser_config::get(qw(wservice wkey wlocation wunits)));
eval
{
    my ($temperature, $time) = $weather->current_temperature();
    my $units = heatmiser_config::get_item('wunits');
    print "External temperature at $time was $temperature$units\n";
};
my $err = $@;

# Display the raw request and response if debugging
if (heatmiser_config::get_item('debug') and exists $weather->{debug})
{
    print "\nRequest:\n" .  $weather->{debug}->{uri} . "\n\n",
          "Response:\n" . $weather->{debug}->{raw} . "\n\n";
}

# That's all folks
die $err if $err;
exit;
