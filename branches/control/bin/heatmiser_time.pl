#!/usr/bin/perl

# This script sets the time and date of a Heatmiser Wi-Fi enabled thermostat
# from the computer's clock.

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
use heatmiser_wifi;

# Command line options
my ($prog) = $0 =~ /([^\\\/]+$)/;
sub VERSION_MESSAGE { print "Heatmiser Wi-Fi Thermostat Time Synchroniser v1\n"; }
sub HELP_MESSAGE { print "Usage: $prog [-h <host>] [-p <pin>] [-v]\n"; }
$Getopt::Std::STANDARD_HELP_VERSION = 1;
our ($opt_h, $opt_p, $opt_v);
getopts('h:p:v');
heatmiser_config::set(host => [h => $opt_h], pin => [p => $opt_p],
                      verbose => $opt_v);

# Loop through all configured hosts
foreach my $host (@{heatmiser_config::get_item('host')})
{
    # Read the thermostat's details
    print "### $host ###\n" if heatmiser_config::get_item('verbose');
    my $heatmiser = new heatmiser_wifi(host => $host,
                                       heatmiser_config::get(qw(pin)));
    my @pre_dcb = $heatmiser->read_dcb();
    my $pre_status = $heatmiser->dcb_to_status(@pre_dcb);

    # The local computer's clock as an SQL DATETIME string
    my ($second, $minute, $hour, $day, $month, $year) = localtime;
    my $now = sprintf '%04i-%02i-%02i %02i:%02i:%02i',
                      1900 + $year, 1 + $month, $day, $hour, $minute, $second;

    # Set the thermostat's clock
    my @items = $heatmiser->status_to_dcb($pre_status, time => $now);
    my @post_dcb = $heatmiser->write_dcb(@items);
    my $post_status = $heatmiser->dcb_to_status(@post_dcb);

    # Display the times if requested
    if (heatmiser_config::get_item('verbose'))
    {
        print "Before:   $pre_status->{time}\n";
        print "Computer: $now\n";
        print "After:    $post_status->{time}\n";
    }
}

# That's all folks
exit;
