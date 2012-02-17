# This is a Perl library for accessing the iPhone interface of Heatmiser's
# range of Wi-Fi enabled thermostats. This has only been tested with the
# PRT-TS Wi-Fi and PRT/HW-TS Wi-Fi models, but it should be relatively easy to
# support the other models in the range (DT-TS Wi-Fi and TM1-TS Wi-Fi).
#
# This software is based on the Heatmiser V3 System Protocol documentation
# (version V3.7). However, it is apparent that there a couple of errors or
# ambiguities in the DCB description in that document:
# - Switching differential is actually in the range 1-6 in units of 0.5C
# - Multi-byte values (length and temperatures) have LSB at the preceding index

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


package heatmiser_wifi;

# Catch errors quickly
use strict;
use warnings;

# Useful libraries
use IO::Socket;
use POSIX qw(strftime);


# Default configuration options
my %default_options =
(
    host    => 'heatmiser',
    port    => 8068,
    pin     => 0000,
    timeout => 5 # (seconds)
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
}


# PROCESSING OF THERMOSTAT DATA

# Decode the contents of the DCB
sub dcb_to_status
{
    my ($self, @dcb) = @_;

    # Sanity check the DCB length field
    my $status;
    $status->{dcblength} = b2w(@dcb[0, 1]);
    die "DCB length mismatch\n" unless $status->{dcblength} == @dcb;

    # Device type and version
    sub lookup { my ($value, %names) = @_; return $names{$value} if exists $names{$value}; return $value; }
    $status->{product} = { vendor => lookup($dcb[2], 0 => 'Heatmiser',
                                                     1 => 'OEM'),
                           version => ($dcb[3] & 0x7f) / 10,
                           model => lookup($dcb[4], 0 => 'DT', 1 => 'DT-E',
                                                    2 => 'PRT', 3 => 'PRT-E',
                                                    4 => 'PRTHW', 5 => 'TM1') };

    # Current date and time
    my $timebase = $status->{product}->{model} =~ /^(PRTHW|TM1)$/ ? 44 : 41;
    $status->{time} = sqldatetime(@dcb[$timebase .. $timebase + 2,
                                       $timebase + 4 .. $timebase + 6]);

    # General operating status
    $status->{enabled} = $dcb[21];
    $status->{keylock} = $dcb[22];

    # Holiday mode
    my (@holiday) = @dcb[25 .. 30];
    $status->{holiday} = { time => sqldatetime(@holiday[0 .. 4]),
                           enabled => $holiday[5] };

    # Fields that only apply to models with thermometers
    if ($status->{product}->{model} ne 'TM1')
    {
        # Temperature configuration
        $status->{config} = { units => lookup($dcb[5], 0 => 'C', 1 => 'F'),
                              switchdiff => $dcb[6] / 2,
                              caloffset => b2w(@dcb[8, 9]),
                              outputdelay => $dcb[10],
                              locklimit => $dcb[12],
                              sensor => lookup($dcb[13], 0 => 'internal', 1 => 'remote', 2 => 'floor', 3 => 'internal + floor', 4 => 'remote + floor'),
                              optimumstart => $dcb[14] };

        # Run mode
        $status->{runmode} = lookup($dcb[23], 0 => 'heating', 1 => 'frost');

        # Frost protection
        $status->{frostprotect} = { enabled => $dcb[7],
                                    target => $dcb[17] };

        # Floor limit
        if ($status->{product}->{model} =~ /-E$/)
        {
            $status->{floorlimit} = { limiting => $dcb[3] >> 7,
                                      floormax => $dcb[20] };
        }

        # Current temperature(s)
        my (@temps) = @dcb[33 .. 38];
        sub temperature { my $t = b2w(@_); $t == 0xffff ? undef : $t / 10; }
        $status->{temperature} = { remote => temperature(@temps[0, 1]),
                                   floor => temperature(@temps[2, 3]),
                                   internal => temperature(@temps[4, 5]) };;

        # Status of heating
        $status->{heating} = { on => $dcb[40],
                               target => $dcb[18],
                               hold => b2w(@dcb[31, 32]) };

        # Learnt rate of temperature rise
        $status->{rateofchange} = $dcb[15];

        # Error code
        $status->{errorcode} = lookup($dcb[39], 0 => undef, 0xE0 => 'internal', 0xE1 => 'floor', 0xE2 => 'remote');
    }

    # Fields that only apply to models with hot water control
    if ($status->{product}->{model} =~ /(HW|TM1)$/)
    {
        # Status of hot water
        $status->{hotwater} = { on => $dcb[43] };
    }

    # Program mode
    $status->{config}->{progmode} = lookup($dcb[16], 0 => '5/2', 1 => '7');

    # Program entries, does not apply to non-programmable thermostats
    if ($status->{product}->{model} !~ /^DT/)
    {
        # Find the start of the program data
        # Weekday/Weekend or Mon/Tue/Wed/Thu/Fri/Sat/Sun
        my $days = $status->{config}->{progmode} eq '5/2' ? 2 : 7;
        my $progbase = $status->{product}->{model} =~ /^(PRTHW|TM1)$/ ? 51 : 48;
        if ($days == 7)
        {
            $progbase += 24 if $status->{product}->{model} =~ /^PRT/;
            $progbase += 32 if $status->{product}->{model} =~ /^(PRTHW|TM1)$/;
        }

        # Heating comfort levels program
        my (@prog) = @dcb[$progbase .. $#dcb];
        if ($status->{product}->{model} =~ /^PRT/)
        {
            foreach my $day (0 .. $days - 1)
            {
                my @day;
                foreach my $entry (0 .. 3)
                {
                    push @day, { time => sqltime(@prog[0, 1]),
                                 target => $prog[2] } if $prog[0] < 24;
                    @prog = @prog[3 .. $#prog];
                }
                push @{$status->{comfort}}, [@day];
            }
        }

        # Hot water control program
        if ($status->{product}->{model} =~ /^(PRTHW|TM1)$/)
        {
            foreach my $day (0 .. $days - 1)
            {
                my @day;
                foreach my $entry (0 .. 3)
                {
                    push @day, { on => sqltime(@prog[0, 1]),
                                 off => sqltime(@prog[2, 3]) } if $prog[0] < 24;
                    @prog = @prog[4 .. $#prog];
                }
                push @{$status->{timer}}, [@day];
            }
        }

        # Check that all data was processed
        warn "DCB longer than expected (" . scalar @prog . " octets unprocessed)\n" if @prog;
    }

    # Return the decoded status
    return $status;
}

# Render the status as text
sub status_to_text
{
    my ($self, $status) = @_;

    # Device type and version
    my (@text);
    push @text, "$status->{product}->{vendor} $status->{product}->{model}"
                . " version $status->{product}->{version}";

    # General operating status
    push @text, 'Thermostat is ' . ($status->{enabled} ? 'ON' : 'OFF');
    $text[-1] .= " ($status->{runmode} mode)" if $status->{enabled} and $status->{runmode};
    push @text, "Key lock active" if $status->{keylock};
    push @text, "Time $status->{time}";

    # Holiday mode
    push @text, "Holiday until $status->{holiday}->{time}" if $status->{holiday}->{enabled};

    # Current temperature(s)
    my $units = "deg $status->{config}->{units}";
    my @temperatures = map { defined $status->{temperature}->{$_} ? "$status->{temperature}->{$_} $units ($_)" : () } qw(internal remote floor);
    push @text, "Temperature " . join(', ', @temperatures) if @temperatures;
    $text[-1] .= '(floor limit active)' if $status->{floorlimit}->{limiting};
    push @text, "Calibration offset $status->{config}->{caloffset}" if $status->{config}->{caloffset};
    push @text, "Error with $status->{errorcode} sensor" if $status->{errorcode};

    # Status of heating
    push @text, "Target $status->{heating}->{target} $units" if $status->{heating}->{target};
    $text[-1] .= " hold for $status->{heating}->{hold} minutes" if $status->{heating}->{hold};
    push @text, 'Heating is ' . ($status->{heating}->{on} ? 'ON' : 'OFF') if defined $status->{heating}->{on};

    # Status of hot water
    push @text, "Hot water boost for $status->{hotwater}->{hold} minutes" if $status->{hotwater}->{hold};
    push @text, 'Hot water is ' . ($status->{hotwater}->{on} ? 'ON' : 'OFF') if defined $status->{hotwater}->{on};

    # Feature table
    my @features =
    (
        ['Temperature format', $status->{config}->{units}],
        ['Switching differential', $status->{config}->{switchdiff}, $units],
        ['Frost protect', $status->{frostprotect}->{enabled}],
        ['Frost temperature', $status->{frostprotect}->{target}, $units],
        ['Output delay', $status->{config}->{outputdelay}, 'minutes'],
        ['Comms #', 'n/a'],
        ['Temperature limit', $status->{config}->{locklimit}, $units],
        ['Sensor selection', $status->{config}->{sensor}],
        ['Floor limit', $status->{floorlimit}->{floormax}, $units],
        ['Optimum start', $status->{config}->{optimumstart} || 'disabled', 'hours'],
        ['Rate of change', $status->{rateofchange}, 'minutes / deg C'],
        ['Program mode', $status->{config}->{progmode}, 'day']
    );
    my $index = 1;
    foreach my $feature (@features)
    {
        my ($desc, $value, $units) = @$feature;
        ($value, $units) = ('n/a', undef) unless defined $value;
        push @text, sprintf "Feature %02i: %-23s %3s %s",
                            $index++, $desc, $value, $units || '';
    }

    # Program entries
    my @days = $status->{config}->{progmode} eq '5/2'
               ? ('Weekday', 'Weekend')
               : ('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday',
                  'Saturday', 'Sunday');
    foreach my $index (0 .. $#days)
    {
        # Convert the comfort levels and timers to text
        sub hhmm { my ($time) = @_; $time =~ s/:00$//; return $time; }
        my @comfort = map { hhmm($_->{time}) . " $_->{target} $units" }
                          @{$status->{comfort}->[$index]};
        my @timer = map { hhmm($_->{on}) . '-' . hhmm($_->{off}) }
                        @{$status->{timer}->[$index]};

        # Add appropriate entries
        my $entry = 1;
        while (@comfort or @timer)
        {
            push @text, sprintf "%-9s %i: %-14s  %s",
                                $entry == 1 ? $days[$index] : '', $entry++,
                                shift @comfort || '', shift @timer || '';
        }
    }

    # Return the result
    return map { s/\s*$/\n/; $_ } @text;
}

# Predict the comfort level for a particular date and time
sub lookup_comfort
{
    my ($self, $status, $datetime) = @_;

    # Default to the time in the status unless explicitly specified
    $datetime = $status->{time} unless $datetime;
    die "Badly formatted time" unless $datetime =~ / (\d\d:\d\d:\d\d)$/;
    my $time = $1;

    # Start with the final temperature for the previous day
    my $mode = $status->{config}->{progmode};
    my $prevdayindex = dateindex($mode, $datetime, -1);
    my $target = $status->{comfort}->[$prevdayindex]->[-1]->{target};

    # And with the first temperature for the next day
    my $nextdayindex = dateindex($mode, $datetime, +1);
    my $next_target = $status->{comfort}->[$nextdayindex]->[0]->{target};

    # Search the levels for the current day for the specified time
    my $dayindex = dateindex($mode, $datetime);
    my $entries = $status->{comfort}->[$dayindex];
    foreach my $entry (@$entries)
    {
        if ($time lt $entry->{time})
        {
            $next_target = $entry->{target};
            last;
        }
        $target = $entry->{target};
    }

    # Return the target temperature(s)
    return wantarray ? ($target, $next_target) : $target;
}

# Predict the hot water state for a particular date and time
sub lookup_timer
{
    my ($self, $status, $datetime) = @_;

    # Default to the time in the status unless explicitly specified
    $datetime = $status->{time} unless $datetime;
    die "Badly formatted time" unless $datetime =~ / (\d\d:\d\d:\d\d)$/;
    my $time = $1;

    # Search the timers for the current day for the specified time
    my $state = 0;
    my $dayindex = dateindex($status->{config}->{progmode}, $datetime);
    my $entries = $status->{timer}->[$dayindex];
    foreach my $entry (@$entries)
    {
        $state = 1 if $entry->{on} le $time and $time lt $entry->{off};
    }

    # Return the hot water state
    return $state;
}


# HIGH LEVEL COMMANDS

# Read the thermostat's status
sub read_dcb
{
    my ($self, $start, $octets) = @_;

    # Construct and issue the inquiry command
    $start = 0x0000 unless defined $start;
    $octets = 0xffff unless defined $octets;
    return undef unless $self->command(0x93, w2b($start), w2b($octets));

    # Read the response
    my ($op, @data) = $self->response();

    # Perform some basic sanity checks on the response
    die "Unexpected opcode in thermostat response\n" unless $op == 0x94;
    die "Start address mismatch in thermostat response\n" unless b2w(@data[0, 1]) == $start;
    my $length = b2w(@data[2, 3]);
    die "Incorrect PIN used\n" unless $length;
    die "Incorrect length of thermostat response\n" unless scalar @data == $length + 4;

    # Return the DCB portion of the response
    return @data[4 .. $#data];
}


# BASIC SOCKET HANDLING

# Open a socket to the thermostat
sub open
{
    my ($self) = @_;

    # No action required if the socket is already open
    return 1 if $self->{socket};

    # Open a socket to the server
    $self->{socket} = IO::Socket::INET->new(PeerAddr => $self->{host}, PeerPort => $self->{port}, Proto => 'tcp', Timeout => $self->{timeout});
    die "Unable to create socket: $!\n" unless $self->{socket};
    $self->{socket}->setsockopt(SOL_SOCKET, SO_RCVTIMEO, pack('L!L!', $self->{timeout}, 0));
    return 1;
}

# Close the socket to the thermostat
sub close
{
    my ($self) = @_;

    # Close the socket
    delete $self->{socket};
    return 1;
}


# LOW LEVEL THERMOSTAT COMMAND TRANSPORT

# Construct an arbitrary thermostat command
sub command
{
    my ($self, $op, @data) = @_;

    # Ensure that a socket is open
    return undef unless $self->open();

    # Construct the command
    my $len = 7 + scalar @data;
    my @cmd = ($op, w2b($len),w2b($self->{pin}), @data);
    push @cmd, w2b(crc16(@cmd));

    # Convert the command to binary
    my $cmd = join('', map(chr, @cmd));

    # Send the command to the thermostat
    $self->{socket}->send($cmd, 0) or die "Failed to send command to thermostat: $!\n";
    return 1;
}

# Deconstruct an arbitrary thermostat response
sub response
{
    my ($self) = @_;

    # Receive a response from the thermostat
    my $rsp;
    $self->{socket}->recv($rsp, 0x10000, 0);
    die "No response received from thermostat\n" unless length $rsp;

    # Split the response into octets
    my (@rsp) = map(ord, split(//, $rsp));

    # Extract interesting fields
    my $op = $rsp[0];
    my $len = b2w($rsp[1], $rsp[2]);
    my @data = @rsp[3 .. ($#rsp - 2)];
    my $crc = b2w(@rsp[-2, -1]);

    # Error checking
    die "Length field mismatch in thermostat response\n" unless $len == scalar @rsp;
    my $crc_actual = crc16(@rsp[0 .. ($#rsp - 2)]);
    die "CRC incorrect in thermostat response\n" unless $crc == $crc_actual;

    # Return the interesting fields
    return ($op, @data);
}

# Calculate thermostat 16-bit CRC
sub crc16
{
    my (@octets) = @_;

    # Process 4 bits of data
    sub crc16_4bits
    {
        my ($crc, $nibble) = @_;

        my (@lookup) = (0x0000, 0x1021, 0x2042, 0x3063,
                        0x4084, 0x50A5, 0x60C6, 0x70E7,
                        0x8108, 0x9129, 0xA14A, 0xB16B,
                        0xC18C, 0xD1AD, 0xE1CE, 0xF1EF);
        return (($crc << 4) & 0xffff) ^ $lookup[($crc >> 12) ^ $nibble];
    }

    # Process the whole message
    my $crc = 0xffff;
    foreach my $octet (@octets)
    {
        $crc = crc16_4bits($crc, $octet >> 4);
        $crc = crc16_4bits($crc, $octet & 0x0f);
    }

    # Return the CRC
    return $crc;
}


# UTILITY FUNCTIONS

# Convert a 16-bit word to octets in little endian format
sub w2b
{
    my ($word) = @_;
    return ($word & 0xFF, $word >> 8);
}

# Convert octets in little endian format to a 16-bit word
sub b2w
{
    my ($lsb, $msb) = @_;
    return $lsb + ($msb << 8);
}

# Convert to SQL DATETIME string format
sub sqldatetime
{
    my ($year, $month, $day, $hour, $minute, $second) = @_;

    # Convert date and time fields to SQL format (YYYY-MM-DD HH:MM:SS)
    return sprintf '%04i-%02i-%02i %02i:%02i:%02i',
                   2000 + $year, $month, $day, $hour, $minute, $second || 0;
}

# Convert to SQL TIME string format
sub sqltime
{
    my ($hour, $minute, $second) = @_;

    # Convert time fields to SQL format (HH:MM:SS)
    return sprintf '%02i:%02i:%02i',
                   $hour, $minute, $second || 0;
}

# Convert a date into a comfort or timer program index
sub dateindex
{
    my ($mode, $date, $offset) = @_;

    # Extract the date fields
    die "Badly formatted date\n" unless $date =~ /^(\d\d\d\d)-(\d\d)-(\d\d)/;
    my ($year, $month, $day) = ($1, $2, $3);

    # Calculate the day of the week (%u would be simpler but is less portable)
    my $wday = strftime('%w', 0, 0, 0, $day, $month - 1, $year - 1900);
    # (0 = Sunday, 1 = Monday, ..., 5 = Friday, 6 = Saturday)

    # Convert the week day into an index, including an optional offset
    my $index = ($wday + 6 + ($offset || 0)) % 7;
    return $mode eq '5/2' ? ($index < 5 ? 0 : 1) : $index;
}


# Module loaded correctly
1;
