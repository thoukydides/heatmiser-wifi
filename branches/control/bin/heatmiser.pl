#!/usr/bin/perl

# This is a simple script to illustrate use of the Heatmiser Wi-Fi Perl
# library for accessing the iPhone interface of Heatmiser's range of Wi-Fi
# enabled thermostats.

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
use Getopt::Std;
use heatmiser_config;
use heatmiser_wifi;

# Command line options
my ($prog) = $0 =~ /([^\\\/]+$)/;
sub VERSION_MESSAGE { print "Heatmiser Wi-Fi Thermostat CLI v1\n"; }
sub HELP_MESSAGE { print "Usage: $prog [-h <host>] [-p <pin>] [-d]\n"; }
$Getopt::Std::STANDARD_HELP_VERSION = 1;
our ($opt_h, $opt_p, $opt_d);
getopts('h:p:d');
heatmiser_config::set(host => [h => $opt_h], pin => [p => $opt_p],
                      debug => $opt_d);

# Loop through all configured hosts
foreach my $host (@{heatmiser_config::get_item('host')})
{
    # Read the current status of the thermostat
    print "### $host ###\n";
    my $heatmiser = new heatmiser_wifi(host => $host,
                                       heatmiser_config::get(qw(pin)));
    my @dcb = $heatmiser->read_dcb();

    # Display the thermostat's status
    if (heatmiser_config::get_item('debug'))
    {
        # Dump the raw DCB data for debugging purposes
        for (my $index = 0; $index < @dcb; $index += 8)
        {
            my $values = scalar @dcb - $index < 8 ? scalar @dcb - $index : 8;
            printf "%11s%-48s # (index %3i - %3i)\n",
                   $index ? '' : 'my @dcb = (',
                   join(', ', map { sprintf '0x%02x', $_ }
                                  @dcb[$index .. $index + $values - 1])
                   . ($index + $values < @dcb ? ',' : ');'),
                   $index, $index + $values - 1;
        }
    }
    else
    {
        # Convert the DCB to readable text
        my $status = $heatmiser->dcb_to_status(@dcb);
        print $heatmiser->status_to_text($status);
    }
}

# That's all folks
exit;
