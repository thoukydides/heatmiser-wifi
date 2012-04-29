# This is a Perl library for retrieving weather observations from online
# services:
#   UK MetOffice DataPoint  http://www.metoffice.gov.uk/public/ddc
#   Weather Underground     http://www.wunderground.com/weather/api
#   iGoogle weather API     (unofficial API)
#   Yahoo! Weather          http://developer.yahoo.com/weather

# Copyright © 2012 Alexander Thoukydides

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


package heatmiser_weather;

# Catch errors quickly
use strict;
use warnings;

# Useful libraries
use LWP::UserAgent;
use POSIX qw(strftime);
use XML::Simple qw(:strict);


# Default configuration options
my %default_options =
(
    wservice  => undef,
    wkey      => undef,
    wlocation => undef,
    wunits    => undef,
    timeout   => 5 # (seconds)
);


# BASIC OBJECT HANDLING

# Constructor
sub new
{
    my ($class, %options) = @_;
    my $self = {};
    bless $self, $class;
    $self->initialise(%options);
    return $self;
}

# Configure and connect to the I/O server
sub initialise
{
    my ($self, %options) = @_;

    # Use defaults unless appropriate options specified
    my ($key, $default);
    while (($key, $default) = each %default_options)
    {
        $self->{$key} = defined $options{$key} ? $options{$key} : $default;
    }

    # Check that a weather service has been configured
    die "No weather service selected\n" unless defined $self->{wservice};

    # Check that an API key has been configured if required
    die "An API key is required for Met Office DataPoint: http://www.metoffice.gov.uk/public/ddc\n" if $self->{wservice} eq 'metoffice' and not defined $self->{wkey};
    die "An API key is required for Weather Underground: http://www.wunderground.com/weather/api\n" if $self->{wservice} eq 'wunderground' and not defined $self->{wkey};

    # Create a user agent
    $self->{ua} = LWP::UserAgent->new(timeout => $self->{timeout});
}


# GENERIC HIGH-LEVEL INTERFACE

sub current_temperature
{
    my ($self) = @_;

    # Ensure that a location has been specified
    die "Cannot read current temperature unless a location is specified"
        unless defined $self->{wlocation};

    # Assume that the observation is for the current time unless specified
    my ($second, $minute, $hour, $day, $month, $year) = localtime;
    $year  += 1900; # (localtime returns number of years since 1900)
    $month += 1;    # (localtime returns month in range 0..1)

    # Dispatch to the appropriate weather service
    my ($temperature);
    if ($self->{wservice} eq 'metoffice')
    {
        # Met Office DataPoint UK
        my $observations = $self->metoffice_observations($self->{wlocation});
        # HERE - Extract the temperature from the returned data
    }
    elsif ($self->{wservice} eq 'wunderground')
    {
        # Weather Underground
        my $conditions = $self->wunderground_conditions($self->{wlocation});
        my $observations = $conditions->{current_observation};
        $temperature = $self->{wunits} eq 'F' ? $observations->{temp_f}
                                              : $observations->{temp_c};
        ($year, $month, $day, $hour, $minute, $second) = rfc822($observations->{observation_time_rfc822});
    }
    elsif ($self->{wservice} eq 'google')
    {
        # iGoogle
        my $api = $self->google_api($self->{wlocation});
        my $conditions = $api->{weather}->{current_conditions};
        $temperature = $self->{wunits} eq 'F' ? $conditions->{temp_f}
                                              : $conditions->{temp_c};
        # (No observation time is returned)
    }
    elsif ($self->{wservice} eq 'yahoo')
    {
        # Yahoo! Weather
        my $rss = $self->yahoo_rss($self->{wlocation}, $self->{wunits});
        my $conditions = $rss->{channel}->{item}->{'yweather:condition'};
        $temperature = $conditions->{temp};
        ($year, $month, $day, $hour, $minute, $second) = rfc822($conditions->{date});
    }
    else
    {
        die "Unsupported weather service '$self->{wservice}'\n";
    }

    # Format the timestamp as an SQL DATETIME string
    my $timestamp = sprintf '%04i-%02i-%02i %02i:%02i:%02i',
                            $year, $month, $day, $hour, $minute, $second;

    # Return the temperature and its timestamp
    return wantarray ? ($temperature, $timestamp) : $temperature;
}


# UK MET OFFICE DATAPOINT

# Retrieve the most recent observations from the Met Office DataPoint service
sub metoffice_observations
{
    my ($self, $location) = @_;

    # HERE - Retrieve the Met Office DataPoint observation data
    die "Met Office DataPoint is not currently supported";
}


# WEATHER UNDERGROUND
# (Note that the free API is limited to 500 calls/day and 10 calls/minute)

# Retrieve the current conditions from Weather Undeground
sub wunderground_conditions
{
    my ($self, $location) = @_;

    # Fetch the weather information
    my $response = $self->{ua}->get('http://api.wunderground.com/api/' . $self->{wkey} . '/conditions/q/' . $location . '.xml');
    die "Failed to retrieve Weather Underground conditions: " . $response->status_line . "\n" unless $response->is_success;

    # Decode and return the result
    return XMLin($response->decoded_content,
                 ForceArray => [], KeyAttr => []);
}


# GOOGLE

# Retrieve the current conditions and forecast from iGoogle
sub google_api
{
    my ($self, $location) = @_;

    # Fetch the weather information
    my $response = $self->{ua}->get('http://www.google.com/ig/api?weather=' . $location);
    die "Failed to retrieve Google weather: " . $response->status_line . "\n" unless $response->is_success;

    # Decode and return the result
    return XMLin($response->decoded_content,
                 ForceArray => ['forecast_conditions'],
                 KeyAttr    => ['day_of_week'],
                 ValueAttr  => ['data']);
}


# YAHOO! WEATHER

# Retrieve the Yahoo! Weather RSS feed
sub yahoo_rss
{
    my ($self, $location, $units) = @_;

    # Fetch the weather information
    my $response = $self->{ua}->get('http://weather.yahooapis.com/forecastrss?w=' . $location . '&u= ' . lc $units);
    die "Failed to retrieve Yahoo! Weather RSS feed: " . $response->status_line . "\n" unless $response->is_success;

    # Decode and return the result
    return XMLin($response->decoded_content,
                 ForceArray => ['yweather:forecast'],
                 KeyAttr    => {'yweather:forecast' => '+date'});
}


# UTILITY FUNCTIONS

# Decode an RFC822 date and time
sub rfc822
{
    my ($rfc822) = @_;

    # Parse the date and time
    die "Not an RFC822 date and time: $rfc822\n" unless $rfc822 =~ /^(?:\w\w\w, )(\d?\d) (\w\w\w) (\d\d\d\d) (\d?\d):(\d\d)(?::(\d\d))?(?: (am|pm))?/i;
    my ($day, $monthname, $year, $hour, $minute, $second, $ampm) = ($1, $2, $3, $4, $5, $6, $7);

    # Map the month name to a number
    my $month = 1;
    foreach (qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec))
    {
        last if $_ eq $monthname;
        ++$month;
    }

    # Seconds are optional
    $second = 0 unless defined $second;

    # Yahoo! Weather uses an AM/PM indicator which is not RFC822 compliant
    if (defined $ampm)
    {
        $hour = 0   if lc $ampm eq 'am' and $hour == 12;
        $hour += 12 if lc $ampm eq 'pm' and $hour < 12;
    }

    # Return the decoded date and time
    return ($year, $month, $day, $hour, $minute, $second);
}


# Module loaded correctly
1;
