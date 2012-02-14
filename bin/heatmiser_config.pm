# This is a Perl library for configuring tools that access the iPhone
# interface of Heatmiser's range of Wi-Fi enabled thermostats. This file
# provides defaults for the main settings that it may be necessary to modify.
# These defaults can be overridden by the following files in the order listed:
#     /etc/heatmiser.conf
#     ~/.heatmiser
#
# The file should contain lines like:
#     HOST        heatmiser1 heatmiser2 heatmiser3
#     PIN         1234
#     LOGSECONDS  1
#     DBSOURCE    dbi:mysql:heatmiser
#     DBUSER      heatmiser
#     DBPASSWORD
#     LOGFILE     /var/log/heatmiser

# Copyright © 2011, 2012 Alexander Thoukydides

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


package heatmiser_config;

# Catch errors quickly
use strict;
use warnings;

# Useful libraries
use File::HomeDir;
use FileHandle;


# Default configuration options ('undef' indicates no default required)
my %config =
(
    dbsource   => undef, # (use default in heatmiser_db.pm module)
    dbuser     => undef, # (use default in heatmiser_db.pm module)
    dbpassword => undef, # (use default in heatmiser_db.pm module)
    logseconds => 60,
    debug      => 0,
    verbose    => 0,
    logfile    => '/var/log/heatmiser'
);

# Possible locations of configuration files
my (@configfiles) = ('/etc/heatmiser.conf',
                     File::HomeDir->my_home . '/.heatmiser');

# Attempt to read the configuration files in the order listed
foreach my $filename (@configfiles)
{
    # Ignore files that do not exist
    next unless -e $filename;

    # Open the configuration file
    my $fh = new FileHandle "< $filename";
    die "Unable to open '$filename' for reading: $!\n" unless $fh;

    # Process the while file
    while (<$fh>)
    {
        # Ignore comments and blank lines
        next if /^#/;
        next unless /^(\w+)(?:\s+(.*?))?\s*$/;

        # Store the value, converting the key to lowercase
        $config{lc $1} = $2;
    }
}

# Override configuration items
sub set
{
    my (%values) = @_;

    # Process all of the specified values
    while (my ($key, $value) = each %values)
    {
        # Extract any command line switch if specified
        my $switch;
        ($switch, $value) = @$value if ref $value eq 'ARRAY';

        # Store the value or report an error if there is no default
        if (defined $value)
        {
            $config{$key} = $value;
        }
        elsif (not exists $config{$key})
        {
            error($key, $switch);
        }
    }
}

# Read configuration items
sub get
{
    my (@keys) = @_;

    # Default to all keys unless specific ones have been requested
    @keys = keys %config unless @keys;

    # Obtain the requested configuration items
    my %requested;
    foreach my $key (@keys)
    {
        # Report an error if there is no value for the requested key
        error($key) unless exists $config{$key};
        my $value = $config{$key};

        # Treat the host field as a space-separated list
        $value = [ split(/\s+/, $value) ] if $key eq 'host';

        # Add this value to the result
        $requested{$key} = $value;
    }

    # Return the requested configuration items
    return %requested;
}

# Read a single configuration item
sub get_item
{
    my ($key) = @_;

    # Return the specified configuration item
    my (%requested) = get($key);
    return $requested{$key};
}

# Report an error for a missing value
sub error
{
    my ($key, $switch) = @_;

    # Provide a helpful error message
    my $solution = "Add '\U$key\E <value>' to " . join(' or ', @configfiles);
    $solution .= "\nAlternatively add '-$switch <value>' to the command line" if $switch;
    die "No value specified for configuration item <$key>\n$solution\n"
}


# Module loaded correctly
1;
