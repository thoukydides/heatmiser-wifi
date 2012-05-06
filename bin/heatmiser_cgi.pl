#!/usr/bin/perl -T

# This CGI script provides access to the database of data logged from the
# iPhone interface of Heatmiser's range of Wi-Fi enabled thermostats.
#
# A symbolic link to this file should be created from
# "/usr/lib/cgi-bin/heatmiser/ajax.pl"
# (or the appropriate cgi-bin directory on the platform being used).

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
use lib (dirname(abs_path $0) =~ /^(.*)$/)[0]; # (clear taintedness)

# Useful libraries
use CGI;
use JSON;
use Time::HiRes qw(time sleep);
use heatmiser_config;
use heatmiser_db;


# Performance profiling
my $time_start = time();
my $time_last = $time_start;
my @time_log;
sub time_log { my $now = time(); push @time_log, [shift, $now - $time_last]; $time_last = $now; }

# Prepare the CGI object
my $cgi = CGI->new;

# Decode the script's parameters
my $thermostat = $cgi->param('thermostat');
my $type = $cgi->param('type') || 'log';
my %range = (from => scalar $cgi->param('from'),
             to => scalar $cgi->param('to'),
             days => scalar $cgi->param('days'));
my %wrange = %range;
$wrange{from} = scalar $cgi->param('wfrom') if $cgi->param('wfrom');
$wrange{to} = scalar $cgi->param('wto') if $cgi->param('wto');
my $timeout = time() + ($cgi->param('timeout') || 10);

# Trap any errors that occur while interrogating the database
my (%results, $db);
eval
{
    # Check range values are numeric (to guard against SQL injection attacks)
    die "Illegal range specified\n" if grep { defined $_ and !/^\d+(?:\.\d+)?$/ } (values %range, values %wrange);

    # Provide a list of thermostats, default to the first if none specified
    $results{thermostats} = heatmiser_config::get_item('host');
    $thermostat = $results{thermostats}->[0] unless $thermostat;
    die "Unknown thermostat specified in request\n"
        unless grep { $thermostat eq $_ } @{$results{thermostats}};

    # Connect to the database (requesting dates as milliseconds since epoch)
    $db = new heatmiser_db(heatmiser_config::get(qw(dbsource dbuser dbpassword)), dateformat => 'javascript');
    time_log('Database connection');

    # Always retrieve the thermostat's settings
    $results{settings} = { $db->settings_retrieve($thermostat) };
    time_log('Database settings query');

    # If requesting new data then wait for up to the timeout value
    if (defined $range{from} and not defined $range{to})
    {
        while (time() < $timeout)
        {
            my $latest = $db->log_retrieve_latest($thermostat, ['time'])->[0];
            last if $range{from} < $latest;
            sleep(1);
        }
        time_log('Wait for new data');
    }

    # Retrieve the requested data
    if ($type eq 'log')
    {
        # Retrieve temperature logs
        my $temperatures = $db->log_retrieve($thermostat,
                                             [qw(time air target comfort)],
                                             \%range);
        time_log('Database temperatures query');
        $results{temperatures} = fixup_uniq($temperatures);
        time_log('Data conversion');

        # Retrieve the heating activity log
        my $heating = $db->events_retrieve($thermostat, [qw(time state)],
                                           'heating', \%range);
        $results{heating} = fixup($heating);
        time_log('Database heating query');

        # Retrieve the target temperature log
        my $target = $db->events_retrieve($thermostat,
                                          [qw(time state temperature)],
                                          'target', \%range);
        $results{target} = fixup($target, sub { ($_[0]+0, $_[1], $_[2]+0) } );
        time_log('Database target query');

        # Retrieve the hot water log
        my $hotwater = $db->events_retrieve($thermostat,
                                            [qw(time state temperature)],
                                            'hotwater', \%range);
        $results{hotwater} = fixup($hotwater, sub { ($_[0]+0, $_[1], $_[2]+0) } );
        time_log('Database hot water query');

        # Retrieve the weather log
        my $weather = $db->weather_retrieve([qw(time external)], \%wrange);
        time_log('Database weather query');
        $results{weather} = fixup_uniq($weather);
        time_log('Data conversion');
    }
    elsif ($type eq 'minmax')
    {
        # Retrieve daily temperature range
        my $temperatures = $db->log_daily_min_max($thermostat, \%range);
        time_log('Database temperatures query');
        $results{temperatures_minmax} = fixup_uniq($temperatures);
        time_log('Data conversion');

        # Retrieve daily weather range
        my $weather = $db->weather_daily_min_max(\%wrange);
        time_log('Database weather query');
        $results{weather_minmax} = fixup_uniq($weather);
        time_log('Data conversion');
    }
    else
    {
        die "Unsupported type specified in request\n";
    }
};
if ($@)
{
    # Include the error message in the result
    my $err = ($@ =~ /^(.*?)\s*$/)[0];
    $results{error} = $err;
    print STDERR "Error during database access: $err\n";
}

# Convert the result to JSON format
$results{profile} = \@time_log;
my $json = encode_json(\%results);
time_log('JSON encoding');

# Return the data
my $status;
$status = '500 ' . $results{error} if exists $results{error};
print $cgi->header('application/json', $status), $json;
time_log('HTTP response');

# Log the profiling information
push @time_log, ['TOTAL', time() - $time_start];
#printf STDERR "%s = %.3f ms\n", $_->[0], $_->[1] * 1000 foreach (@time_log);

# That's all folks!
exit;


# Filter out rows that only differ by date and convert text to numbers for JSON
sub fixup_uniq
{
    my ($in) = @_;

    # Process every row
    my ($out, $values, $prev_values) = ([], '', '');
    foreach my $row (@$in)
    {
        # Skip over duplicates (ignoring the time field), except last entry
        ($prev_values, $values) = ($values, join(',', @$row[1 .. $#$row]));
        next if $values eq $prev_values and $row->[0] != $in->[-1]->[0];

        # Convert all values to numbers
        push @$out, [map { $_ + 0 } @$row];
    }

    # Return the result
    return $out;
}

# Convert text to numbers for JSON
sub fixup
{
    my ($in, $sub) = @_;

    # Default is to fix every column
    $sub = sub { map { $_ + 0 } @_ } unless defined $sub;

    # Process every row and return the result
    return [map {[ $sub->(@$_) ]} @$in];
}
