#!/usr/bin/perl

# This script provides a JSON interface to access the iPhone interface of
# Heatmiser's range of Wi-Fi enabled thermostats from languages other than
# Perl.

# Copyright © 2013 Alexander Thoukydides
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
use JSON;
use heatmiser_config;
use heatmiser_wifi;

# Command line options
my ($prog) = $0 =~ /([^\\\/]+$)/;
sub VERSION_MESSAGE { print "Heatmiser Wi-Fi Thermostat JSON Interface v1\n"; }
sub HELP_MESSAGE { print "Usage: $prog [-h <host>] [-p <pin>] [JSON DCB]\n"; }
$Getopt::Std::STANDARD_HELP_VERSION = 1;
our ($opt_h, $opt_p);
getopts('h:p:');
heatmiser_config::set(host => [h => $opt_h], pin => [p => $opt_p]);
my $items;
$items = decode_json(join(' ', @ARGV)) if @ARGV;

# Loop through all configured hosts
my (%status);
foreach my $host (@{heatmiser_config::get_item('host')})
{
    # Read the current status of the thermostat
    my $heatmiser = new heatmiser_wifi(host => $host,
                                       heatmiser_config::get(qw(pin)));
    my @pre_dcb = $heatmiser->read_dcb();
    my $status = $heatmiser->dcb_to_status(@pre_dcb);

    # Write any specified items to the thermostat
    if ($items)
    {
        my @items = $heatmiser->status_to_dcb($status, %$items);
        my @post_dcb = $heatmiser->write_dcb(@items);
        $status = $heatmiser->dcb_to_status(@post_dcb);
    }

    # Store the decoded status
    $status{$host} = $status;
}

# Output the status in JSON format
print JSON->new->utf8->pretty->canonical->encode(\%status);

# That's all folks
exit;
