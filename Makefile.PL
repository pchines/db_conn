# This -*- perl -*- script writes the Makefile for NHGRI::Db::Connector
# $Id: Makefile.PL,v 1.23 2010/01/21 21:04:15 pchines Exp $

use strict;
use ExtUtils::MakeMaker;
# use lib so we use the current version, rather than previously installed one
use lib 'lib';
use NHGRI::Db::Connector qw(ask ask_pass);
use File::Spec;

$main::MODULE_FILE = 'lib/NHGRI/Db/Connector.pm';
$main::CONFIG_LOCAL = 'db_connector.cfg';
$main::CONFIG_PATH  = '/usr/local/etc/db_connector.cfg';
$main::TEST_REALM_FILE = './test';
$main::TEST_REALM_LIVE = $main::TEST_REALM_FILE . ".live";
$main::SH_REGEX = q{^(\s*\$SHARED_CONNECTION_DIR\s*=\s*)'(.*?)'\s*;\s*$};
$main::PR_REGEX = q{^(\s*\$PRIVATE_SUBDIR_IN_HOME\s*=\s*)'(.*?)'\s*;\s*$};
$main::PQ_REGEX = q{^(\s*\$QUERY_SEARCH_PATH\s*=\s*)'(.*?)'\s*;\s*$};
$main::PQ_FILE = 'pquery.plx';

# Set Module defaults
print << "INTRO";

The answers to the following questions will be used to configure the
NHGRI::Db::Connector module.  Please take the time to read the instructions
and answer carefully.  When a default answer is provided in square brackets,
you can accept the default by pressing the return key.  You may run
'perl Makefile.PL' again to change your answers.
INTRO

$main::CONFIG_PATH = get_config_path();
create_local_config();
set_config_path($main::CONFIG_PATH, $main::MODULE_FILE);
#set_config_path($main::CONFIG_PATH, $main::PQ_FILE);
$main::PUB_DIR = get_shared_dir();
my $priv_dir   = get_private_dir();
# TODO: remove pquery?
#$main::PQ_PATH = get_query_dir();
set_connection_dirs($main::PUB_DIR, $priv_dir, $main::PQ_PATH);

# Create a default realm file for testing
my $dbd = get_dbd();
if ($dbd) {
    my $server   = get_server();
    my $user     = get_user();
    my $pass     = get_pass();
    my $database = get_database();
    NHGRI::Db::Connector->write_realm_file(
        FILENAME => $main::TEST_REALM_FILE,
        DBD      => $dbd,
        SERVER   => $server,
        USER     => $user,
        PASS     => $pass,
        DATABASE => $database,
        );
    if (ask_do_live_test() =~ /^y/i) {
        NHGRI::Db::Connector->write_realm_file(
        FILENAME => $main::TEST_REALM_LIVE,
        DBD      => $dbd,
        SERVER   => $server,
        USER     => $user,
        PASS     => $pass,
        DATABASE => $database,
        );
    }
    else {  # no live test
        unlink $main::TEST_REALM_LIVE;
    }
}
else {  # no test
    print "No DBD supplied; assuming no database account for testing\n",
        "Will skip remaining questions and most tests.\n\n";
}

# Write the Makefile (with customizations from the MY:: methods below)
WriteMakefile(
    'NAME'         => 'NHGRI::Db::Connector',
    'VERSION_FROM' => $main::MODULE_FILE,
    'PREREQ_PM'    => {
            DBI             => 1.0,
            'Text::Balanced'=> 0,
            },
    'EXE_FILES'    => [qw(dbc_realm dbc_passwd)],
    'AUTHOR'       => 'Peter Chines <pchines@cpan.org>',
    'ABSTRACT_FROM'=> $main::MODULE_FILE,
    'LICENSE'      => 'perl',
);
if ($dbd && !do "Test/Cmd.pm") {
    print << "TESTCMD";
To run the complete set of tests, you must install the Test::Cmd module.
However, this module is not required to install or run NHGRI::Db::Connector.

TESTCMD
}
if (!$NHGRI::Db::Connector::USE_READKEY) {
    print << "READKEY";
It is recommended that you install the Term::ReadKey module.  This will enable
dbc_passwd to accept passwords without displaying them on the screen.

READKEY
}
my (undef, $path, undef) = File::Spec->splitpath($main::CONFIG_PATH);
if (!-d $path) {
    print << "CREATE_DIR";
The directory '$path' does not exist.
Please create this directory before running 'make install'.

CREATE_DIR
}

##### End of MAIN

##### Makefile customizations

sub MY::postamble {
    return << "RULE";
install :: install_config_file install_connection_dir install_query_dir

install_config_file:
\t\$(CP) $main::CONFIG_LOCAL $main::CONFIG_PATH

install_connection_dir:
\t-\$(MKPATH) $main::PUB_DIR
\t\@echo
\t\@echo To finish setting up NHGRI::Db::Connector:
\t\@echo 1. Remember to set proper permissions for $main::PUB_DIR
\t\@echo    and $main::PQ_PATH
\t\@echo 2. Create new database realms by running the dbc_realm script
\t\@echo 3. Delete test realm files--make realclean will do this for you

install_query_dir:
\t-\$(MKPATH) `perl -e 'join " ", split ":", $ARGV[0]' $main::PQ_PATH`

realclean :: clean_realm_file clean_local_config

clean_realm_file:
\t-\$(RM_F) $main::TEST_REALM_FILE $main::TEST_REALM_LIVE

clean_local_config:
\t-\$(RM_F) $main::CONFIG_LOCAL
RULE
}

##### Helper procedures

sub create_local_config {
    # Use existing config file, if possible
    if (-e $main::CONFIG_LOCAL) {
        my ($sh, $pr, $pq) = _read_config($main::CONFIG_LOCAL);
        return 1 if $sh && $pr && $pq;
        warn "Invalid data in '$main::CONFIG_LOCAL', overwriting\n";
    }
    my $config;
    if (-e $main::CONFIG_PATH) {
        open IN, $main::CONFIG_PATH or die;
        warn "Using existing configuration from '$main::CONFIG_PATH' "
            . "as defaults\n";
        $config = join '', <IN>;
    }
    else {
        $config = << 'DEFAULT_CONFIG';
# Configuration file for perl module NHGRI::Db::Connector
# Run perldoc NHGRI::Db::Connector for details
DEFAULT_CONFIG
    }
    if ($config !~ /$main::SH_REGEX/) {
        $config .= << 'DEFAULT_CONFIG'

# Location of shared connector realm files:
$SHARED_CONNECTION_DIR = '/usr/local/share/db_connections';
DEFAULT_CONFIG
    }
    if ($config !~ /$main::PR_REGEX/) {
        $config .= << 'DEFAULT_CONFIG'

# Location of private realm files (relative to user's HOME directory):
$PRIVATE_SUBDIR_IN_HOME = '.db_connections';
DEFAULT_CONFIG
    }
# TODO: remove pquery?
#    if ($config !~ /$main::PQ_REGEX/) {
#        $config .= << 'DEFAULT_CONFIG'
#
## Location of pquery (.psql) files:
#$QUERY_SEARCH_PATH = '/usr/local/share/pquery';
#DEFAULT_CONFIG
#    }
    open OUT, ">$main::CONFIG_LOCAL"
        or die "Can't write $main::CONFIG_LOCAL, $!\n";
    print OUT $config;
    close OUT or die "Error writing to $main::CONFIG_LOCAL, $!\n";
}

sub _read_config {
    my ($file) = @_;
    my ($sh, $pr, $pq);
    open IN, $file or return;
    while (<IN>) {
        $sh = $2 if /$main::SH_REGEX/;
        $pr = $2 if /$main::PR_REGEX/;
        $pq = $2 if /$main::PQ_REGEX/;
    }
    return ($sh, $pr, $pq);
}

# Modify local config file
sub set_connection_dirs {
    my ($pub_dir, $priv_dir, $pq_path) = @_;

    my ($found_shared, $found_private, $found_query);
    # Read first and then write, to preserve comments
    # and avoid having to create a temp file
    open IN, $main::CONFIG_LOCAL or die "Cannot open $main::CONFIG_LOCAL, $!";
    my @lines = <IN>;
    close IN;
    open OUT, ">$main::CONFIG_LOCAL"
        or die "Can't write $main::CONFIG_LOCAL, $!";
    foreach (@lines) {
        if (/$main::SH_REGEX/) {
            print OUT "$1'$pub_dir';\n";
            $found_shared = 1;
        }
        elsif (/$main::PR_REGEX/) {
            print OUT "$1'$priv_dir';\n";
            $found_private = 1;
        }
        elsif (/$main::PQ_REGEX/) {
            print OUT "$1'$pq_path';\n";
            $found_query = 1;
        }
        else {
            print OUT;
        }
    }
    close OUT or die "Error writing to $main::CONFIG_LOCAL, $!";
#    if (!$found_shared || !$found_private || !$found_query) {
    if (!$found_shared || !$found_private) {
        warn "FATAL ERROR: Could not find \$SHARED_CONNECTION_DIR\n"
            if !$found_shared;
        warn "FATAL ERROR: Could not find \$PRIVATE_SUBDIR_IN_HOME\n"
            if !$found_private;
#        warn "FATAL ERROR: Could not find \$QUERY_SEARCH_PATH\n"
#            if !$found_query;
        die "The local config file '$main::LOCAL_CONFIG' is out of sync\n"
            . "with this Makefile; please delete it.\n";
    }
}

sub set_config_path {
    my ($path, $file) = @_;
    open IN, $file or die "Can't open $file, $!\n";
    my @lines = <IN>;
    close IN;
    open OUT, ">$file"
        or die "Can't write to $file, $!\n";
    my $found = 0;
    foreach (@lines) {
        if (/^(\s*)do '([^']*)';\s*$/) {
            print OUT $1, "do '$path';\n";
            ++$found;
        }
        else {
            print OUT;
        }
    }
    close OUT or die "Error writing to $file, $!\n";
    if ($found != 1) {
        die "FATAL ERROR: Could not find config path in $file.\n"
            . "Module is corrupted; please start from a fresh distribution.\n"
    }
}

sub get_config_path {
    my $dir;
    open IN, $main::MODULE_FILE or die "Can't open $main::MODULE_FILE, $!\n";
    while (<IN>) {
        if (/^\s*do '([^']*)';$/) {
            $dir = $1;
        }
    }
    die "FATAL ERROR: Could not find config path in $main::MODULE_FILE.\n"
        . "The module is corrupted; please start from a fresh distribution.\n"
        if !$dir;
    print << "END";

The 'global configuration file' tells where to store shared and private
realm files.  The configuration file will be automatically generated by
this installation procedure, and installed when you 'make install', but
the destination directory where it will reside should already exist.

END
    return get_abs_path("Global configuration file:", $dir);
}

sub get_abs_path {
    my ($prompt, $dir) = @_;
    $dir = ask($prompt, $dir);
    while (!File::Spec->file_name_is_absolute($dir)) {
        $dir = File::Spec->rel2abs($dir);
        print "\nThe directory you entered was not an absolute path.\n";
        $dir = ask($prompt, $dir);
    }
    return $dir;
}

sub get_query_dir {
    my (undef, undef, $dir) = _read_config($main::CONFIG_LOCAL);
    print << "END";

The 'shared query directory' is the place to store pqueries that will be
shared by multiple users.  Files stored in this directory must be
readable by all of the users that will use each query.  The shared query
directory must be specified as an absolute path (i.e. one beginning with
/ for Unix, a drive letter for DOS/Windows, etc.)  This directory
need not exist yet; it will be created when you 'make install'.

END
    return get_abs_path("Shared query directory:", $dir);
}

sub get_shared_dir {
    my ($dir, undef) = _read_config($main::CONFIG_LOCAL);
    die "FATAL ERROR: Could not find \$SHARED_CONNECTION_DIR in config file\n"
        . "The local config file '$main::LOCAL_CONFIG' is out of sync\n"
        . "with this Makefile; please delete it.\n"
        if !$dir;
    print << "END";

The 'shared connection directory' is the place to store connections that will
be shared by multiple users.  Information stored in this directory must be
readable by all of the users that will access the database via these
connections.  This means that all of these users will have access to the
database passwords, and that protecting this information from other users 
relies on the filesystem permissions that you set.  It is recommended that
shared connections be limited to database accounts with read-only access to
the database.  The shared connection directory must be specified as an
absolute path (i.e. one beginning with / for Unix, a drive letter for
DOS/Windows, etc.)  This directory need not exist yet; it will be created
when you 'make install'.

END
    return get_abs_path("Shared connection directory:", $dir);
}

sub get_private_dir {
    my (undef, $dir) = _read_config($main::CONFIG_LOCAL);
    die "FATAL ERROR: Could not find \$PRIVATE_SUBDIR_IN_HOME in config file\n"
        . "The local config file '$main::LOCAL_CONFIG' is out of sync\n"
        . "with this Makefile; please delete it.\n"
        if !$dir;
    print << "END";

The 'private connection directory' is the place to store connections that
belong to a single user.  The permissions on this directory should be set so
that only the owner can read the connection files (e.g. 0700 in Unix).  The
directory name is specified relative to the user's home directory, as
established by the HOME environment variable.  So, for example, a private
connection directory of '.db' would indicate that private files should be
located in $ENV{HOME}/.db for you, and analogous locations for other users.

END
    $dir = ask("Private connection directory:", $dir);
    while (File::Spec->file_name_is_absolute($dir)) {
        (undef, undef, $dir) = File::Spec->splitpath($dir);
        print "\nThe directory you entered was an absolute path.\n";
        $dir = ask("Private connection directory:", $dir);
    }
    return $dir;
}

sub get_dbd {
    print << "END";

Now please supply connection parameters to connect to a database, for testing
purposes.  This information will only be used for testing that this module
works, when you type 'make test'.  The data, including the password, will be
written to a 'test' file in this directory.  Make sure you change the
permissions on this file, or delete it once you are done testing and
installing this module.

The first thing needed to make the database connection is the name of the DBD
(database dependent) driver to use.  This driver must already be installed on
your system in order for the connection to work.  For example, if you use
DBD::Sybase, enter 'Sybase'.  If you use DBD::mysql, enter 'mysql'.  This
parameter is case-sensitive, and corresponds to the part of the DBI DSN that
appears immediately after the 'dbi:'.  This parameter is required.

END
    my $rh = read_test_realm();
    return ask("DBD driver:", $rh->{'DBD'});
}

sub get_server {
    print << "END";

The next parameter is the server connect string.  This is a free-form string
that can contain different things depending on the database dependent driver
that you are using.  Typically, it consists of a number of key=value
statements, separated by semicolons.  As a special case, if no equals signs
appear in the string, it is interpreted as the name of the server, as if
'server=' was prepended to the string.

Examples of common connect strings: for Sybase, just the name of the server,
e.g. 'SYBASE'; for Oracle, the name of the instance, e.g. 'ORA1'; for mySQL,
'host=fqdn.com;port=3335', or leave blank if the server is on localhost.

END
    my $rh = read_test_realm();
    return ask("Server connect string:", $rh->{'SERVER'});
}

sub get_user {
    print << "END";

For most databases, a username and password are required to connect; if this
is not true for your database, you can leave these blank.

END
    my $rh = read_test_realm();
    return ask("Username:", $rh->{'USER'});
}

sub get_pass {
    my $rh = read_test_realm();
    return ask_pass("Password:", $rh->{'PASS'});
}

sub get_database {
    print << "END";

For many database management systems, a single server can host many
databases.  While you would ordinarily choose a database in the server
connect string, some databases allow you to issue a 'use' command after
connecting to choose the database to connect to.  If you supply a database
name here, NHGRI::Db::Connector will issue a 'use <database>' command upon
connecting.  If unsure, leave this blank.

END
    my $rh = read_test_realm();
    return ask("Database to use:", $rh->{'DATABASE'} || undef);
}

sub read_test_realm {
    if (-e $main::TEST_REALM_FILE) {
        return NHGRI::Db::Connector->read_realm_file(
            -FILENAME => $main::TEST_REALM_FILE);
    }
    else {
        return {};
    }
}

sub ask_do_live_test {
    print << "END";

Do you want to perform change password tests on this database?  This will
temporarily change the password for this account (to "new_pass") and
immediately change it back.  Not recommended for live production databases.

END
    my $prev = -e $main::TEST_REALM_LIVE ? 'Y' : 'N';
    return ask("Change password? (Y/N) ", $prev);
}
