# $Id: Connector.pm,v 1.33 2013/01/26 02:41:44 pchines Exp $
package NHGRI::Db::Connector;

use strict;
use vars qw(@EXPORT_OK @ISA $VERSION
        $SHARED_CONNECTION_DIR @PARAMS $USE_READKEY
        $PRIVATE_CONNECTION_DIR $PRIVATE_SUBDIR_IN_HOME
        $MAX_WAIT $MIN_INTERVAL $MAX_INTERVAL
        );
use Exporter;
use Carp;
use DBI;
use File::Spec;
eval q{
    use Term::ReadKey;
    $USE_READKEY = 1;
};

$VERSION = '0.80a';
@ISA = qw(Exporter);
@EXPORT_OK = qw(ask ask_pass);
@PARAMS = qw(DBD SERVER USER PASS DATABASE);

# Set the default directories where database realm connection files
# will be stored

$SHARED_CONNECTION_DIR   = '/usr/local/share/db_connections';
$PRIVATE_SUBDIR_IN_HOME  = '.db_connections';
$MAX_WAIT     = 0;       # total wait time (zero = no retries)
$MIN_INTERVAL = '1sec';  # start value: doubles each iteration
$MAX_INTERVAL = '10min'; # ... up to max interval
# Read in config values for above variables, if file exists
if ($ENV{'DBC_CONFIG_FILE'}) {
    do "$ENV{'DBC_CONFIG_FILE'}";
}
else {
    do '/usr/local/etc/db_connector.cfg';
}
if ($ENV{'HOME'} && $PRIVATE_SUBDIR_IN_HOME) {
    $PRIVATE_CONNECTION_DIR = File::Spec->join($ENV{'HOME'},
            $PRIVATE_SUBDIR_IN_HOME);
}
# Override with environment variables, if present
if ($ENV{'DBC_SHARED_DIR'}) {
    $SHARED_CONNECTION_DIR = $ENV{'DBC_SHARED_DIR'};
}
if ($ENV{'DBC_PRIVATE_DIR'}) {
    $PRIVATE_CONNECTION_DIR = $ENV{'DBC_PRIVATE_DIR'};
}
# all times specified in seconds; use _time_to_sec() for easy conversion
$MAX_WAIT     = _time_to_sec($MAX_WAIT);
$MIN_INTERVAL = _time_to_sec($MIN_INTERVAL);
$MAX_INTERVAL = _time_to_sec($MAX_INTERVAL);

##
## Public Methods
##

sub new {
    my $pkg = shift;
    my $rh_args = _normalize(@_);
    my $self = {
        dir              => $rh_args->{'CONNECTION_DIR'}
            || $SHARED_CONNECTION_DIR,
        realm            => delete $rh_args->{'REALM'} || 'default',
        dbi_attrib       => delete $rh_args->{'DBI_ATTRIB'} 
            || delete $rh_args->{'DBI_OPTIONS'} || {},
        no_disconnect    => delete $rh_args->{'NO_DISCONNECT'},
        max_wait         => delete $rh_args->{'MAX_WAIT'},
        min_interval     => delete $rh_args->{'MIN_INTERVAL'},
        max_interval     => delete $rh_args->{'MAX_INTERVAL'},
        callback         => delete $rh_args->{'CALLBACK'},
    };
    if (!delete $rh_args->{'CONNECTION_DIR'}) {
        $self->{'priv_dir'} = $PRIVATE_CONNECTION_DIR;
    }
    # warn for any extra options:
    my $extra = join("", map { "\t$_ => '$rh_args->{$_}'\n" }
            sort keys %$rh_args);
    carp "NHGRI::Db::Connector: did not understand these parameters "
        ."(please check spelling):\n$extra" if $extra;

    bless $self, ref $pkg || $pkg;
    for my $tf (qw(max_wait min_interval max_interval)) {
        $self->{$tf} = _time_to_sec($self->{$tf}) if $self->{$tf};
    }
    # Test to see if realm exists, so we find out sooner, rather than later
    $self->find_realm_file();
    return $self;
}

sub clone {
    my $self = shift;
    my $pkg = ref($self) || croak "clone: can only be called on an object";
    my $dir;
    if ($self->{dir} ne $SHARED_CONNECTION_DIR) {
        $dir = $self->{dir};
    }
    return $pkg->new(
            REALM           => $self->{realm},
            CONNECTION_DIR  => $dir,
            DBI_ATTRIB      => $self->{dbi_attrib},
            NO_DISCONNECT   => $self->{no_disconnect},
            MAX_WAIT        => $self->{max_wait},
            MAX_INTERVAL    => $self->{max_interval},
            CALLBACK        => $self->{callback},
            );
}

sub connect {
    my $self = shift;

    if ($self->{dbh} && $self->{dbh}->ping()) {
        return $self->{dbh};
    }

    my $rh_params   = $self->read_realm_file();
    my $data_source = 'DBI:' . $rh_params->{DBD} . ':' . $rh_params->{SERVER};
    my $username    = $rh_params->{USER};
    my $password    = $rh_params->{PASS};
    my $database    = $rh_params->{DATABASE};

    my $rh_options  = $self->{'dbi_attrib'}
        || $rh_params->{DBI_ATTRIB};
    my $max_wait    = defined $self->{'max_wait'}    ? $self->{'max_wait'}
                    : defined $rh_params->{MAX_WAIT} ? $rh_params->{MAX_WAIT}
                    :                                  $MAX_WAIT;
    my $max_interval= $self->{'max_interval'}
        || $rh_params->{MAX_INTERVAL} || $MAX_INTERVAL;

    my $current  = time;
    my $start    = $current;
    my $end      = $start + $max_wait;
    my $interval = $self->_next_interval(0, $max_interval);
    my $dbh;
    while (1) {
        eval {
            $dbh = DBI->connect($data_source, $username, $password, $rh_options)
                || die $DBI::errstr;
        };
        last if !$@ && $dbh;
        if ($self->{callback}) {
            $self->{callback}->(
                    realm   => $self->{realm},
                    start   => $start,
                    interval=> $interval,
                    end     => $end,
                    errstr  => $@,
                    );
        }
        if ($current + $interval >= $end) {
            my $msg = "Failed to connect to database";
            if ($max_wait) {
                $msg .= sprintf " after %d seconds; next %ds interval "
                    . "exceeds time limit", $current-$start, $interval;
            }
            die "$msg: $@";
        }
        if ($@ =~ /install_driver/) {
            die $@;
        }
        sleep $interval;
        $interval = $self->_next_interval($interval, $max_interval);
        $current = time;
    }

    if ($database) {
        $dbh->do("use $database")
            || die "Failed to 'use $database':\n$DBI::errstr";
    }

    $self->{dbh} = $dbh;
    return $dbh;
}

sub disconnect {
    my ($self) = @_;
    if (my $dbh = $self->{dbh}) {
        if (!$dbh->FETCH('AutoCommit')) {
            $dbh->rollback();
        }
        $dbh->disconnect();
        $self->{dbh} = undef;
    }
}

sub read_realm_file {
    my $self = shift;
    my $rh_args = _normalize(@_);
    my $filename;
    if ($rh_args->{'FILENAME'}) {
        $filename = $rh_args->{'FILENAME'}
    }
    else {
        my $realm = $rh_args->{'REALM'} || $self->{'realm'};
        $filename = $self->find_realm_file($realm);
    }
    my $valid = join("|", @PARAMS);

    my %param;
    local *CONF;
    open(CONF, $filename)
        || die "Cannot read database realm file '$filename', $!\n";
    while (<CONF>) {
        next if /^\s*#/ || /^\s*$/;
        if (/^\s*($valid)\s*=\s*(.*)/o) {
            $param{$1} = $2;
        }
        else {
            warn "Ignoring unexpected database configuration parameter at "
                ."line $. of '$filename' realm file:\n$_"
        }
    }
    close CONF;
    return \%param;
}

sub write_realm_file {
    my $self = shift;
    my $rh_args = _normalize(@_);
    croak "write_realm_file: DBD parameter is required"
        unless $rh_args->{'DBD'};

    my $filename;
    if ($rh_args->{'FILENAME'}) {
        $filename = $rh_args->{'FILENAME'};
    }
    else {
        my $realm = $rh_args->{'REALM'} || $self->{'realm'};
        if ($rh_args->{'SHARED'}) {
            $filename = $self->_get_shared_realm_file($realm);
        }
        else {
            $filename = $self->_get_private_realm_file($realm)
                || $self->_get_shared_realm_file($realm);
        }
    }

    local *CONF;
    open(CONF, ">$filename") || die "Can't write to '$filename', $!\n";
    foreach my $key (@PARAMS) {
        print CONF "$key=", $rh_args->{$key}||'', "\n";
    }
    close CONF || die "Error closing '$filename', $!\n";
}

##
## Exportable functions
##

sub ask {
    my ($prompt, $default) = @_;

    print $prompt . " ";
    if (defined $default) { 
        print "[$default] ";
    }
    my $response = <STDIN>;
    chomp $response;
    if ($response eq '' && defined $default) {
        $response = $default;
    }
    return $response;
}

sub ask_pass {
    my ($prompt, $default) = @_;
    print $prompt . " ";
    if (defined $default) {
        print "[", "*" x length($default), "] ";
    }
    if ($USE_READKEY) {
        ReadMode('noecho');
    }
    else {
        system("stty", "-echo");
    }
    my $response = <STDIN>;
    print "\n";
    if ($USE_READKEY) {
        ReadMode('normal');
    }
    else {
        system("stty", "echo");
    }
    chomp $response;
    if ($response eq '' && defined $default) {
        $response = $default;
    }
    return $response;
}

# find_realm_file
# Finds the file for the specified database realm.
# If a connection directory was specified in the constructor,
# it checks only that directory.  Standard behavior is to
# first check if there is a private realm by that name,
# and if not, then check if there is a shared realm.
# If no matching realm file is found, it croaks.
sub find_realm_file {
    my $self  = shift;
    my $realm = shift || $self->{'realm'};
    my $msg = "using ";

    # First try private realm
    my $filename = $self->_get_private_realm_file($realm);
    if ($filename && -e $filename) {
        return $filename;
    }
    $msg .= $filename ? "private realm '$filename', nor"
                      : "no private realm dir,";

    # Then try shared dir
    $filename = $self->_get_shared_realm_file($realm);
    if ($filename && -e $filename) {
        return $filename;
    }
    $msg .= "\nshared realm $filename.\nfrom module " . __FILE__ ;
    
    croak "The database realm '$realm' cannot be found $msg";
}

##
## The remaining functions and methods are PRIVATE
##

sub _get_private_realm_file {
    my $self  = shift;
    my $realm = shift || $self->{'realm'};
    my $filename;
    if (!ref $self && $PRIVATE_CONNECTION_DIR) {
        $filename = File::Spec->join($PRIVATE_CONNECTION_DIR, $realm);
    }
    elsif (ref $self && $self->{'priv_dir'}) {
        $filename = File::Spec->join($self->{'priv_dir'}, $realm);
    }
    return $filename;
}

sub _get_shared_realm_file {
    my $self  = shift;
    my $realm = shift || $self->{'realm'};
    my $filename;
    if (ref $self) {
        $filename = File::Spec->join($self->{'dir'}, $realm);
    }
    else {
        $filename = File::Spec->join($SHARED_CONNECTION_DIR, $realm);
    }
    return $filename;
}

sub _next_interval {
    my ($self, $cur_interval, $max_interval) = @_;
    $max_interval ||= $self->{'max_interval'} || $MAX_INTERVAL;
    my $last = $cur_interval || ($self->{'min_interval'} || $MIN_INTERVAL)/2;
    my $next = $last + $last;
    if ($next > $max_interval) {
        $next = $max_interval;
    }
    return $next;
}

sub _time_to_sec {
    my ($time) = @_;
    $time =~ s/[,\s]+//g;
    if ($time =~ /^(\d*(?:\.\d*)?)
                   (d(?:a?y)?
                   |h(?:(?:ou)?r)?
                   |m(?:in(?:ute)?)?
                   |s(?:ec(?:ond)?)?
                   )s?$/ix) {
        $time = $1 || 1;
        my $unit = $2;
        if ($unit !~ /^s/i) {
            $time *= 60;
        }
        if ($unit =~ /^[dh]/i) {
            $time *= 60;
        }
        if ($unit =~ /^d/i) {
            $time *= 24;
        }
    }
    elsif ($time !~ /^\d+(?:\.\d*)?$/) {
        croak "Time value '$_[0]' not understood.\n"
            . "Acceptable suffixes are d[ay], h[our], m[in], s[ec], "
            . "and their plurals";
    }
    return $time;
}

# removes initial dash (if any) and converts to uppercase
sub _normalize {
    my %params = @_;
    my %normal;
    while (my ($key,$value) = each %params) {
        $key =~ s/^-//;
        $normal{uc($key)} = $value;
    }
    return \%normal;
}

# Automatically disconnect from the database when connector 
# goes out of scope, unless user specified NO_DISCONNECT
sub DESTROY {
    my $self = shift;
    if (!$self->{no_disconnect}) {
        $self->disconnect();
    }
}

1;

__END__

=head1 NAME

NHGRI::Db::Connector - centralize and personalize database connection parameters

=head1 SYNOPSIS

  use NHGRI::Db::Connector;

  my $dbc = new NHGRI::Db::Connector(-realm => 'pubs2');

  my $dbh = $dbc->connect();

  ... (use DBI handle in the normal way; don't disconnect)

=head1 DESCRIPTION

The database connector is a perl module that can be used to
get a DBI database handle without having to hardcode any of
the database connection parameters into your perl scripts or
modules.

This makes it easy to:

=over 4

=item * Perform Database Migration

Change the database that any number of scripts use by editing a single
file.  Ditto for changing usernames and passwords.

=item * Use the Same Code in Development and Production

You can define the same realm name differently on development and production
servers, so that each accesses a different database without changing a single
line of code.

=item * Simplify Security

Allow users to connect to the database with their own username and
database-enforced permissions without having to supply their password
every time they run the script.

Also allows you to define a level of shared access (e.g. a read-only
connection) to be used as the default if no user-specific permissions are
granted.

=item * Cache Database Connections

Save time by avoiding having to make a new connection to the database for
each database access, without having to pass a DBI database handle around
from one routine to another.  The NHGRI::Db::Connector only makes a database
connection if you need one, so if your script never uses the database, your
program takes no performance hit.

=item * Re-establish Lost Database Connections

When a database connection is lost (e.g. due to timeout, backup,
maintenance), you can configure the module to periodically attempt to
re-connect, for a given period of time, rather than simply aborting.

=back

=head1 USING NHGRI::Db::Connector

=head2 Creating

my $dbc = new NHGRI::Db::Connector(-realm =E<gt> 'pubs2');

At the beginning of your program create a new database 
connector C<$dbc>.  Creating the dbc object does not connect
to the database, so this step is very fast.

It will frequently make sense to make the C<$dbc> object a module-level
or global variable.

=head2 Connecting 

my $dbh = $dbc-E<gt>connect();

Pass the connection object C<$dbc> around in your program, 
and whenever you need to access the database, ask for 
a database handle by calling connect.

=head2 Reusing

my $dbh = $dbc-E<gt>connect();

Don't worry about keeping the database handle around, 
or disconnecting from the database.  Just use the handle 
when you need it, and don't disconnect when you are 
finished.  Just keep passing the connection C<$dbc> 
around in your program, and when you want another database
handle, call connect again.

The Database Connector caches the DBI handle, so each subsequent
time you call connect, you reuse the existing database connection.
This can save a substantial amount of time.

=head2 Disconnecting

The database connector will disconnect automatically 
when your program exits or the connector goes out of 
scope.  If you really want to disconnect from the database 
destroy the connector object by setting it to another value,
e.g. C<$dbc = undef;>.  The automatic destructor
will disconnect from the database for you.

There are rare circumstances, e.g. when forking a child process,
when it is necessary to disconnect and destroy the DBI handle, without
destroying the connector object.  In these instances, use the disconnect()
method on the connector object.  Never call disconnect() on the DBI handle
itself.

=head2 Specifying an alternative connection directory

You may read the realm file from a non-standard directory.  This is not
usually recommended, since it foregoes some of the benefits of using
NHGRI::Db::Connector.  Nevertheless, it is sometimes useful.  When you specify a
connection directory explicitly, I<only> this directory is searched;
NHGRI::Db::Connector does not search your private connection directory or the
standard shared directory.

  my $dbc = new NHGRI::Db::Connector(
      -realm          => 'pubs2', 
      -connection_dir => '/other/dir',
  );

See also L</ENVIRONMENT VARIABLES>.

=head2 Passing optional parameters to DBI

You can pass any additional parameters that you would ordinarily pass in the
fourth parameter to DBI->connect() in the C<-dbi_attrib> parameter:

  my $dbc = new NHGRI::Db::Connector(
      -realm       => 'pubs2',
      -dbi_attrib  => {
          RaiseError => 1,
          PrintError => 0, 
          AutoCommit => 1,
      }
  );

=head1 PUBLIC METHODS

=head2 new

Creates a database connector for the specified database realm.

  Usage:    my $dbc = NHGRI::Db::Connector->new();
  Args:     -realm          => realm name, default is 'default'
            -connection_dir => directory where realm files are
                               stored; default is configured at
                               install time
            -dbi_attrib     => reference to a hash of parameters
                               to be passed to DBI->connect()
            -no_disconnect  => optional flag, if true DBI connection
                               is not disconnected when $dbc goes out
                               of scope.
            -max_wait       => if non-zero value is provided, connector
                               will attempt to reconnect to database if
                               server is unavailable or connection is
                               lost; maximum total time to wait
            -min_interval   => initial interval to wait before attempting
                               to reconnect; defaults to 1 second. After
                               each unsuccessful attempt, the interval
                               between attempts doubles, until the
                               max_interval is reached.
            -max_interval   => maximum time to wait between connect
                               attempts; defaults to 10min.
            -callback       => reference to a function to be called each
                               time connection fails; function will receive
                               a hash with the following elements:
                                realm   => realm name
                                start   => epoch seconds when connect first
                                           failed
                                interval=> wait time until next attempt
                                end     => epoch seconds after which no
                                           further attempts will be made 
                                errmsg  => error message as reported by DBI
  Returns:  a new NHGRI::Db::Connector object
  Except:   croaks if the specified realm does not exist

=head2 connect

Return a DBI database handle.  This handle is cached, so that subsequent
calls to this method return the cached database handle rather than making a
new database connection.

If connection object has been properly configured (using -max_wait option),
this method will repeatedly attempt to connect to the database for the
specified time, and will only die when the time is exceeded.

  Usage:    my $dbh = $dbc->connect();
  Args:     none
  Returns:  DBI database handle
  Except:   dies on failure to connect to database

=head2 read_realm_file

Read the realm (database connection) file and return the parameters as a hash
reference.

  Usage:    my $rh = $dbc->read_realm_file();
  Args:     -filename   => (optional) read the specified file
            -realm      => (optional) read the specified realm,
                           rather than the one $dbc was created with
  Returns:  reference to a hash with keys DBD, SERVER, USER, PASS and
            DATABASE.
  Except:   dies if can't read realm file,
            warns if encounter unknown (possibly misspelled?) key
            in realm file

=head2 write_realm_file

Write a realm file.

  Usage:    $dbc->write_realm_file(
                DBD    => 'Sybase',
                SERVER => 'SYB1',
                USER   => 'username',
                PASS   => 'password',
            );
  Args:     -realm  => realm to write (default is same as $dbc realm)
            -dbd    => DBD (required)
            -server => DBI connection string
            -user   => user name
            -pass   => password
            -shared => true value indicates that the file should be
                       written to the shared connection directory
                       (default is to create in private directory)
            -filename => override realm name and private/shared
                       connection directory, specifying full path to
                       realm file to write
  Returns:  nothing
  Except:   dies if can't write file

=head2 find_realm_file

Return the path to the realm file that is being, or would be, used.  This is
primarily for debugging purposes.

  Usage:    $filename = $dbc->find_realm_file();
            or
            $filename = $dbc->find_realm_file($realm_name);

  Args:     optional realm name; default is realm that connector is using
  Returns:  path to realm file
  Except:   dies if realm file cannot be found

=head2 disconnect

Disconnect from the database.  This is rarely necessary.  About the only time
I can think of is before forking a child process, so that both parent and
child do not try to share the same socket to the database.

  Usage:    $dbc->disconnect();
  Args:     none
  Returns:  nothing

=head1 EXPORTABLE FUNCTIONS

Primarily for internal use.

=head2 ask

Ask user for a response to the question/prompt provided.  Response is read
from Standard Input.  If a default value is provided, user can retain the
default simply by pressing just the return key.

  Usage:    my $answer = ask($prompt);
            my $answer = ask($prompt, $default);
  Args:     $prompt  - prompt displayed to the user
            $default - default value to use if user just presses return
  Returns:  user response

Note that this is not a method, but a subroutine designed for export.  To use
it in your own script, you should import the ask() method when you C<use>
NHGRI::Db::Connector, e.g.:

    use NHGRI::Db::Connector qw(ask);

=head2 ask_pass

Same as ask(), but displays default value as asterisks, and does not echo the
user's response to the screen.  Primarily to be used to request passwords.

If the C<Term::ReadKey> module is installed, it is used to disable terminal
echo in a portable manner.  If not, this routine falls back to using the
C<stty> utility.  If the C<stty> program is not available, this routine will
continue to work, but will not hide the user's typing.  The best solution is to
install C<Term::ReadKey>.

=head1 SETUP

There is some set up that must be done before you can
start using the database connector.

=head2 Installation

ALWAYS use the standard Perl installation process:

    perl Makefile.PL
    make
    make test
    make install

and answer all of the questions carefully.  This will ensure that your
standard directories are configured correctly, and if the tests run cleanly,
your environment is ready for use with NHGRI::Db::Connector.

=head2 Establish Connection Directory Permissions

One of the decisions you make during the installation procedure is where you
want to keep the shared realm files that hold the database connection
parameters.  When you install NHGRI::Db::Connector, this directory is created,
using the umask and other information of the user performing the installation
(usually root).

You must decide who should have the ability to create and modify shared
database realm files and set the permissions on this directory accordingly.
Everyone who uses the NHGRI::Db::Connector will need the ability to access (in
Unix, the 'execute' bit) this directory, and to read the particular realm
files that they are allowed to use.

=head2 Database Realm Connection Files

Realm connection files are most easily created using the C<dbc_realm>
script installed along with the NHGRI::Db::Connector.  See L<dbc_realm> for
details.

When users want to change their passwords, this process is simplified
by the C<dbc_passwd> script, which changes both the database password and
the realm file at the same time.  See L<dbc_passwd> for details.
    
Use of the helper programs is optional.  A realm file is simply a text file,
and you can create them manually if you prefer.  A realm file holds all of
the information that DBI will need to connect to your database and create a
database handle.

The format of the file is a series of KEY=VALUE lines.  The following values,
and only these values, are expected:

=over 4

=item *

DBD=Sybase

The database-dependent (DBD) driver to use for this connection.
Always required.

=item *

SERVER=SYBASE

The connect string for the database server to connect to.  The values allowed
here depend on the DBD driver that you are using.  Some database servers will
not use this parameter.  If yours does not, just leave it blank.  In general,
this parameter corresponds to everything that appears in the DBI connection
string after the second colon: e.g. "dbi:DriverName:$SERVER".

=item *

USER=username

The username to use when connecting to the database.  Most databases require
a username for authentication; if yours doesn't, you can leave this blank.

=item *

PASS=password

The password that goes with the above username.  Most databases require a
password for authentication; if yours doesn't, you can leave this blank.

=item *

DATABASE=pubs2

The name of the database on the database server to use.  If you specify a
name here, a C<use database> command will be issued, to switch to the
database you specify.  If your database server does not host multiple
databases or does not support the C<use> statement, leave this parameter
blank.

=back

=head1 ENVIRONMENT VARIABLES

Normally, the locations of the shared and private realm file directories are
set by a global configuration file, typically located at
/usr/local/etc/dbix_connector.cfg (though the location of this file can be
modified during the installation procedure).

You may override the settings in this file by setting environment variables.
DBC_SHARED_DIR specifies the location of shared realm files, and
DBC_PRIVATE_DIR specifies the location of private realm files.

=head1 TROUBLESHOOTING

Normally, the Connector object manages the lifetime of the DBI connection
handle.  When the Connector object goes out of scope, the DBI handle is
disconnected.  Typically, the Connector is a global variable, or top-level
lexical that doesn't go out of scope until the program terminates.  That
means this won't work:

    # Warning: incorrect code
    sub get_dbh {
        my $dbc = NHGRI::Db::Connector->new(-realm => 'mydb');
        return $dbc->connect();
    }

because the $dbc object is destroyed at the end of the subroutine, and thus
the DBI handle returned from the connect() method is disconnected from the
database.

There are two ways of avoiding this problem.  The preferred way is to make
the Connector a global, and just call the connect() method on this global
when you want a DBI handle, e.g.

    our $Dbc = NHGRI::Db::Connector->new(-realm => 'mydb');
    ...
    my $dbh = $Dbc->connect();

The other way is to manage the lifetime of the DBI handle on your own.  To do
this, set the -no_disconnect flag when you create the NHGRI::Db::Connector object.
By doing this, you give up some of the benefits of NHGRI::Db::Connector, but if
this is what you want, I won't stop you--that isn't the Perl way.

=head1 AUTHORS

 Peter S. Chines <pchines@psc.web66.com>
 Anthony J. Masiello <anthony@masiello.org>
 Kenneth Trout <mizumi@fred.net>

=head1 COPYING

Copyright (c)2002-2004, Peter S. Chines.  You may use, modify, and distribute
this software under the same terms as Perl itself.

=head1 SEE ALSO

L<dbc_realm>, L<dbc_passwd>, L<DBI>, and of course, perl(1).

=cut
