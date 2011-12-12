# This is a Perl library for storing the data from the iPhone interface of
# Heatmiser's range of Wi-Fi enabled thermostats in a MySQL database.
#
# Before this is used for the first time it is necessary to create a database
# called 'heatmiser' and a local user called 'heatmiser' with suitable
# access permissions. This can be done with:
#   mysql -u root -p
#   CREATE DATABASE heatmiser;
#   CREATE USER 'heatmiser'@'localhost';
#   GRANT ALL ON heatmiser.* TO 'heatmiser'@'localhost';

# Copyright © 2011 Alexander Thoukydides

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


package heatmiser_db;

# Catch errors quickly
use strict;
use warnings;

# Useful libraries
use DBI;


# Default configuration options
my %default_options =
(
    dbsource   => 'dbi:mysql:heatmiser',
    dbuser     => 'heatmiser',
    dbpassword => '',
    dateformat => 'mysql' # or 'javascript' for milliseconds since 1 Jan 1970
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

    # Connect to the database
    $self->{db} = DBI->connect($self->{dbsource},
                               $self->{dbuser}, $self->{dbpassword})
        or die "Cannot connect to database: $DBI::errstr\n";

    # Die if an error occurs
    $self->{db}->{PrintError} = 0;
    $self->{db}->{RaiseError} = 1;

    # Use explicit transactions for updating the database
    $self->{db}->{AutoCommit} = 0;

    # Prevent timezone conversions for non-MySQL date formats
    $self->{db}->do("SET time_zone='+00:00'");

    # Create any missing tables
    $self->{db}->do('CREATE TABLE IF NOT EXISTS settings (name VARCHAR(20), value VARCHAR(255), PRIMARY KEY (name))');
    $self->{db}->do('CREATE TABLE IF NOT EXISTS comfort (day TINYINT(1), entry TINYINT(1), time TIME, target TINYINT(2), PRIMARY KEY (day, entry))');
    $self->{db}->do('CREATE TABLE IF NOT EXISTS temperatures (time DATETIME, air DECIMAL(3,1), target TINYINT(2), comfort TINYINT(2), PRIMARY KEY (time))');
    $self->{db}->do("CREATE TABLE IF NOT EXISTS events (time DATETIME NOT NULL, class VARCHAR(20) NOT NULL, state VARCHAR(20), temperature TINYINT(2))");
}

# Destructor
sub DESTROY
{
    my ($self) = @_;

    # Disconnect cleanly from the database
    $self->{db}->disconnect() if $self->{db};
}


# DATABASE TABLE UPDATE

# Add an entry to an arbitrary table
sub x_insert
{
    my ($self, $table, %entry) = @_;

    # Prepare the SQL statement to insert a new table entry
    my @fields = sort keys %entry; # (consistent order to allow cacheing)
    my @values = @entry{@fields};
    my $sql = sprintf 'INSERT INTO %s (%s) VALUES (%s)',
                      $table, join(',', @fields), join(',', ('?') x @fields);
    my $insert = $self->{db}->prepare_cached($sql);

    # Insert this entry into the database
    $insert->execute(@values);
    $self->{db}->commit();
}

# Add a log entry
sub log_insert
{
    my ($self, %log) = @_;

    # Insert a new log entry into the database
    $self->x_insert('temperatures', %log);
}

# Add an event entry
sub event_insert
{
    my ($self, %event) = @_;

    # Insert a new event entry into the database
    $self->x_insert('events', %event);
}

# Replace the thermostat settings
sub settings_update
{
    my ($self, %settings) = @_;

    # Perform the update as a single transaction
    eval
    {
        # Prepare the SQL statements to modify settings table entries
        my $replace = $self->{db}->prepare_cached('REPLACE settings (name, value) VALUES (?,?)');
        my $names = $self->{db}->prepare_cached('SELECT name FROM settings');
        my $delete = $self->{db}->prepare_cached('DELETE FROM settings WHERE (name=?)');

        # Update all specified settings entries
        while (my ($name, $value) = each %settings)
        {
            $replace->execute($name, $value);
        }

        # Delete any settings for which values were not specified
        $names->execute();
        my @names = map { $_->[0] } @{$names->fetchall_arrayref()};
        foreach my $name (grep { not exists $settings{$_} } @names)
        {
            $delete->execute($name);
        }

        # Commit the changes
        $self->{db}->commit();
    };
    if ($@)
    {
        # Rollback the incomplete changes
        eval { $self->{db}->rollback };
        die "Settings update transaction aborted: $@\n";
    }
}

# Replace the comfort levels
sub comfort_update
{
    my ($self, $comfort) = @_;

    # Perform the update as a single transaction
    eval
    {
        # Prepare the SQL statements to modify comfort table entries
        my $replace = $self->{db}->prepare_cached('REPLACE comfort (day, entry, time, target) VALUES (?,?,?,?)');
        my $delete = $self->{db}->prepare_cached('DELETE FROM comfort WHERE (day=?) AND (entry=?)');

        # Update all possible table entries (7 days, 4 entries per day)
        foreach my $day (0 .. 6)
        {
            foreach my $entry (0 .. 3)
            {
                my $detail = $comfort->[$day]->[$entry];
                if ($detail)
                {
                    $replace->execute($day, $entry, $detail->{time}, $detail->{target});
                }
                else
                {
                    $delete->execute($day, $entry);
                }
            }
        }

        # Commit the changes
        $self->{db}->commit();
    };
    if ($@)
    {
        # Rollback the incomplete changes
        eval { $self->{db}->rollback };
        die "Comfort levels update transaction aborted: $@\n";
    }
}


# DATABASE TABLE QUERIES

# HERE - Add options to retrieve weekdate/weekend or mon/tue/wed/...
# HERE - Add options to group by hour, 5 minutes, etc...

# Retrieve specified log entries
sub log_retrieve
{
    my ($self, $fields, $where, $groupby) = @_;

# Test grouping to hours
#$groupby = 'ROUND(UNIX_TIMESTAMP(time)/(60*60))';
# Test grouping to five minutes
#$groupby = 'ROUND(UNIX_TIMESTAMP(time)/(5*60))';

    # Construct columns to retrieve
    my @fields = @$fields;
    foreach my $field (@fields)
    {
        # Convert dates to the selected format
        $field = $self->date_from_mysql($field) if $field eq 'time';

        # Aggregated data
        if (defined $groupby)
        {
            my $op = $field =~ /^(target|comfort)$/ ? 'MAX' : 'AVG';
            $op = uc $1 if $field =~ s/^(min|max|avg|count)_//i;
            $field = "$op($field)";
        }
    }

    # Convert a range specification into a WHERE clause
    $where = $self->where_range($where) if ref $where eq 'HASH';

    # Prepare the SQL statement to retrieve each log entry
    my $sql = 'SELECT ' . join(',', @fields) . ' FROM temperatures';
    $sql .= ' WHERE ' . $where if defined $where;
    $sql .= ' GROUP BY ' . $groupby if defined $groupby;
    $sql .= ' ORDER BY time' unless defined $groupby;

    # Fetch and return all matching rows
    return $self->{db}->selectall_arrayref($sql);
}

# Retrieve the most recent log entry
sub log_retrieve_latest
{
    my ($self, $fields) = @_;

    # Fetch and return the matching row
    return $self->log_retrieve($fields,
                               'time = (SELECT MAX(time) FROM temperatures)')->[0];
}

# Determine the daily min/max temperatures
sub log_daily_min_max
{
    my ($self, $where) = @_;

    # Fetch and return all matching rows
    return $self->log_retrieve([qw(time min_air max_air)],
                               $where, 'DATE(time)');
}

# Retrieve specified event entries
sub events_retrieve
{
    my ($self, $fields, $class, $where) = @_;

    # Construct columns to retrieve
    my @fields = @$fields;
    foreach my $field (@fields)
    {
        # Convert dates to the selected format
        $field = $self->date_from_mysql($field) if $field eq 'time';
    }

    # Convert a range specification into a WHERE clause
    $where = $self->where_range($where) if ref $where eq 'HASH';

    # Prepare the SQL statement to retrieve each event entry
    my $sql = 'SELECT ' . join(',', @fields) . ' FROM events';
    $sql .= " WHERE class='" . $class . "'";
    $sql .= ' AND (' . $where . ')' if defined $where;
    $sql .= ' ORDER BY time';

    # Fetch and return all matching rows
    return $self->{db}->selectall_arrayref($sql);
}

# Retrieve the settings
sub settings_retrieve
{
    my ($self) = @_;

    # Prepare the SQL statement to retrieve the settings
    my $sql = 'SELECT name, value FROM settings';

    # Fetch and return all rows converted back to a hash
    my $statement = $self->{db}->prepare_cached($sql);
    $statement->execute();
    return map { @$_ } @{$statement->fetchall_arrayref()};
}

# Retrieve the comfort levels
sub comfort_retrieve
{
    my ($self) = @_;

    # Prepare the SQL statement to retrieve the comfort levels
    my $sql = 'SELECT * FROM comfort';

    # Fetch all rows and convert back to a multi-dimensional table
    my $statement = $self->{db}->prepare_cached($sql);
    $statement->execute();
    my $comfort;
    while (my $row = $statement->fetchrow_hashref())
    {
        $comfort->[$row->{day}]->[$row->{entry}] = { time => $row->{time},
                                                     target => $row->{target} };
    }

    # Return the result
    return $comfort;
}


# SQL WHERE CLAUSE GENERATION

# Range of dates and/or number of recent days
sub where_range
{
    my ($self, $range) = @_;

    # Construct the WHERE clause
    my @where;
    push @where, "DATE_SUB(NOW(), INTERVAL $range->{days} DAY) <= time" if defined $range->{days};
    push @where, $self->date_to_mysql($range->{from}) . ' <= time' if defined $range->{from};
    push @where, 'time < ' . $self->date_to_mysql($range->{to}) if defined $range->{to};

    # Return the result
    return @where ? '(' . join(' AND ', @where) . ')' : undef;
}


# SQL TO CONVERT BETWEEN DATE FORMATS

# Convert selected date format to MySQL
sub date_to_mysql
{
    my ($self, $date) = @_;

    # Return the appropriate SQL for the selected date format
    return "FROM_UNIXTIME($date/1000)" if $self->{dateformat} eq 'javascript';
    return $date; # (otherwise assume MySQL format)
}

# Use Javascript date format (milliseconds since 1st January 1970 epoch)
sub date_from_mysql
{
    my ($self, $date) = @_;

    # Return the appropriate SQL for the selected date format
    return "(UNIX_TIMESTAMP($date)*1000)" if $self->{dateformat} eq 'javascript';
    return $date; # (otherwise assume MySQL format)
}


# Module loaded correctly
1;
