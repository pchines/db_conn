#!/usr/bin/perl -w -I/group/boehnke/lib/perl5
# $Id: pquery.plx,v 1.1 2008/08/08 16:46:34 pchines Exp $

use strict;
use warnings;
use Getopt::Long;
use Pod::Usage;
use NHGRI::Db::Connector;
use File::Spec;
use IO::File;
use Text::Balanced qw(extract_bracketed);

# colon-separated search path (Always implicitly includes current directory)
our $QUERY_SEARCH_PATH;
do '/usr/local/etc/dbix_connector.cfg';
our $DEFAULT_SEARCH_PATH = '.:' . File::Spec->join($ENV{HOME}, "pquery")
    . ($QUERY_SEARCH_PATH ? ":$QUERY_SEARCH_PATH" : '');
if ($ENV{PQUERY_PATH}) {
    $DEFAULT_SEARCH_PATH = $ENV{PQUERY_PATH};
}

our $DEFAULT_REALM = 'results';
our $FORMAT_REGEX = qr/(%-?\d*(?:\.\d+)?\w)/;
our $ANY = 'ANY';

=head1 NAME

pquery.plx - run parameterized query with interactive prompts

=head1 SYNOPSIS

Parse and execute a parameterized query with interactive prompts:

  pquery.plx query.psql > output.txt

Parse query and save SQL to a file:

  pquery.plx -noexec query > new.sql

List all available queries in query path:

  pquery.plx -list

For complete documentation:

  pquery.plx -man

=head1 DESCRIPTION

This program will prompt users for values to fill in the parameters in the
given query, then either return the processed query (if the --noexec option
is specified) or execute the query and return the results in tab-delimited
format.

Additional options allow specification of output formatting and the ability
to provide the necessary parameter values via the commandline.

For convenience in entering large values, e.g. chromosome start or end
positions, this program will allow 'k' or 'm' to be used as suffixes denoting
multiples of 1000 or 1,000,000, respectively.  This convention applies to all
parameter values--defaults as well as user-supplied values.  Numbers,
followed by 'k', 'kb', 'm', or 'mb' will be multiplied by 1000 or 1,000,000.
For example, '10kb' will be translated to 10,000, and '.5mb' will be
translated to 500,000.  For this substitution to apply, the field cannot have
any other leading or trailing characters.

=cut

our %Opt;
our $Dbc;
our $OutFh;
our @ColumnFormat;
our $ColumnCount;

my $EMPTY = q{};
my $COMMA = q{,};
my $SPACE = q{ };

#------------
# Begin MAIN 
#------------

process_commandline();
if ($Opt{template}) {
    write_template($ARGV[0]);
    exit;
}
my $sql = eval_query($ARGV[0]);
if ($Opt{sql}) {
    write_sql($sql);
}
if (!$Opt{noexecute}) {
    write_results($sql)
}

#------------
# End MAIN
#------------

sub eval_query {
    my ($qfile) = @_;
    my ($psql, $rh_var) = read_query($qfile);
    get_values($rh_var);
    my $sql = $psql;
    my @nonlist_vars = grep { !$rh_var->{$_}{list} } keys %$rh_var;
    for my $v (@nonlist_vars) {
        if ($rh_var->{$v}{value} =~ /^$ANY$/i && !$rh_var->{$v}{nolists}) {
            # Replace with 1=1, rather than removing altogether to preserve
            # surrounding syntax without having to fully parse it
            $sql =~ s{
                      (?:not\s*)?       # optional negation
                      [\w\.]+\s*        # column
                      [<>=!]{1,2}\s*    # operator
                      (['"]?)
                      \Q$Opt{openbrace}$v$Opt{closebrace}\E
                      \1}
                     {1=1}xig;     #'for vim
            if ($sql =~ /(.{0,30}       # capture context
                         \Q$Opt{openbrace}$v$Opt{closebrace}\E
                         .{0,30})/x) {
                warn << "END_WARNING";
Warning!  Tried to remove expressions involving variable '$v'
but some instances of the variable do not match simple 'field op value'
pattern and could not be removed.  These may produce an invalid SQL query:
  $1

Please rewrite query to use expected syntax for removable "ANY" variables:
     table.column OP $Opt{openbrace}$v$Opt{closebrace}
  OR table.column OP '$Opt{openbrace}$v$Opt{closebrace}'
where 'OP' may be any one of =, !=, <=, >=, <>, < or >

Alternatively, use the --template option to get a new copy of the query, and
remove the criteria that are not needed for your present query.  Or if
possible, simply choose a value for the parameter that allows all rows.

END_WARNING
            }
        }
        $sql =~ s/\Q$Opt{openbrace}$v$Opt{closebrace}\E/$rh_var->{$v}{value}/g;
    }
    my @list_vars = grep { $rh_var->{$_}{list} } keys %$rh_var;
    for my $v (@list_vars) {
        $sql = replace_list_var($sql, $v, $rh_var->{$v}{list});
    }
    # /gm modifiers may be necessary, if/when multiple queries supported
    if ($sql =~ /^\s*SELECT\s(.+?)\sFROM\s/is) {
        my $fields = $1;
        if ($fields =~ m{/\*\s*$FORMAT_REGEX\s*\*/}xism) {
            column_formats_from_query($fields);
        }
        # For select queries, apply limit, replacing any existing one
        if (defined $Opt{limit}) {
            $sql =~ s/\blimit\s+\d+(?:,\d+)\s*$//is;
            $sql .= "\nlimit $Opt{limit}";
        }
    }
    if ($Opt{strip_comments}) {
        $sql =~ s{/\*.?\*/}{}sg;
    }
    return $sql;
}

sub get_values {
    my ($rh_var) = @_;
    my @vnames = sort { $rh_var->{$a}{order} <=> $rh_var->{$b}{order} }
        keys %$rh_var;
    for my $v (@vnames) {
        if (defined $Opt{var}{$v}) {
            $rh_var->{$v}{value} = $Opt{var}{$v};
        }
        elsif ($Opt{defaults}) {
            if (defined $rh_var->{$v}{default}) {
                $rh_var->{$v}{value} = $rh_var->{$v}{default};
            }
            else {
                die "No value provided for '$v' parameter\n";
            }
        }
        else {
            my $msg = $rh_var->{$v}{prompt};
            $msg =~ s/\s+$//;
            $msg ||= $rh_var->{$v}{name};
            $msg .= '?';
            $rh_var->{$v}{value} = prompt($msg,
                    $rh_var->{$v}{name}, $rh_var->{$v}{default});
        }
        if ($rh_var->{$v}{value}) {
            if ($rh_var->{$v}{value} =~ /^(\d*\.?\d+)kb?$/i) {
                $rh_var->{$v}{value} = $1 * 1000;
            }
            elsif ($rh_var->{$v}{value} =~ /^(\d*\.?\d+)mb?$/i) {
                $rh_var->{$v}{value} = $1 * 1_000_000;
            }
            elsif ($rh_var->{$v}{value} =~ s/^@//) {
                $rh_var->{$v}{list} = read_list($rh_var->{$v}{value});
            }
            elsif (!$rh_var->{$v}{nolists}) {
                # protect escaped commas
                $rh_var->{$v}{value} =~ s/\\$COMMA/\034/g;
                if ($rh_var->{$v}{value} =~ /$COMMA/) {
                    my @list = split $COMMA, $rh_var->{$v}{value};
                    # restore escaped commas
                    for (@list) {
                        s/\034/$COMMA/g;
                    }
                    $rh_var->{$v}{list} = \@list;
                }
                # restore escaped commas
                $rh_var->{$v}{value} =~ s/\034/$COMMA/g;
            }
        }
    }
}

sub read_list {
    my ($file) = @_;
    if (open LIST, "< $file") {
        my @list;
        while (<LIST>) {
            chomp;
            next if /^#/;
            push @list, $_;
        }
        if (!@list) {
            warn "No non-comment lines in '$file'; "
                . "this will not produce a valid query\n";
        }
        elsif ($Opt{debug}) {
            warn sprintf("Read %d items from '$file'\n", scalar(@list), $file);
        }
        return \@list;
    }
    else {
        warn "Unable to open file '$file', $!\n";
        return [$file];
    }
}

sub prompt {
    my ($msg, $name, $def) = @_;
    if (defined $def) {
        if ($Opt{debug}) {
            $msg .= " [$name=$def]";
        }
        else {
            $msg .= " [$def]";
        }
    } elsif ($Opt{debug}) {
        $msg .= " [$name=]";
	}
    print STDERR $msg, $SPACE;
    my $ans = <STDIN>;
    if (defined $ans) {
        chomp $ans;
    }
    else {
        $ans = $EMPTY;
        print STDERR "\n";
    }
    if ($ans eq $EMPTY && defined $def) {
        $ans = $def;
    }
    return $ans;
}

sub read_query {
    my ($qfile) = @_;
    my $file = find_file($qfile);
    open QIN, $file or die "Can't read '$file', $!\n";
    my (%var, $sql, $order);
    while (<QIN>) {
        if (s/^##\s*//) {
            if (/^DefaultDb\s*:\s*(\w+)/) {
                $Opt{dbc_realm} ||= $1;
                $Dbc = NHGRI::Db::Connector->new(realm => $Opt{dbc_realm});
            }
            print STDERR;
        }
        elsif (/^\#([:=])\s*    # '#=' for reg vars, '#:' for non-list vars
                (\w+)           # var name
                \s*:\s*         # colon req'd
                ([^\[]*)        # description (can't contain '[')
                (?:\[           # because optional square brackets indicate
                 ([^\]]*)       # default value (can't contain ']')
                 \])?
                \s*(.*?)\s*$    # anything else (allows default to appear 1st)
                /x) {
            $var{$2} = {
                name     => $2,
                prompt   => $3.$5 || $2,
                default  => $4,
                nolists  => $1 eq ':',
                order    => ++$order,
            };
        }
        elsif (/^#/) {
            next;
        }
        else {
            $sql .= $_;
        }
    }
    # Expected variables (described in headers)
    my @evars = keys %var;
    # Make sure to include the actual vars found in query
    my @avars = ($sql =~ /
            \Q$Opt{openbrace}\E
            ([^\Q$Opt{closebrace}\E]+)
            \Q$Opt{closebrace}\E
            /gx);
    my $ra_missing = list_subtract(\@avars, \@evars);
    for my $v (@$ra_missing) {
        if ($Opt{debug}) {
            warn "Variable '$v' is not defined, but is used in query\n";
        }
        $var{$v} ||= { name => $v, prompt => $v, order => ++$order };
    }
    # Don't bother to ask irrelevant questions
    my $ra_extra = list_subtract(\@evars, \@avars);
    for my $v (@$ra_extra) {
        if ($Opt{debug}) {
            warn "Extra variable '$v' defined, but not used\n";
        }
        delete $var{$v};
    }
    # In debug mode, warn about missing default values
    if ($Opt{debug}) {
        for my $v (sort keys %var) {
            if (!defined $var{$v}{default}) {
                warn "No default value provided for variable '$v'\n";
            }
        }
    }
    return ($sql, \%var);
}

sub list_subtract {
    my ($ra1, $ra2) = @_;
    my %remove;
    @remove{@$ra2} = ();
    my @left = grep { !exists $remove{$_} } @$ra1;
    return \@left;
}

sub write_template {
    my ($qname) = @_;
    my $qfile = find_file($qname);
    open QIN, $qfile or die "Can't read '$qfile', $!\n";
    my $tmpl = $EMPTY;
    while (<QIN>) {
        $tmpl .= $_;
    }
    for my $v (keys %{ $Opt{var} }) {
        if ($Opt{var}{$v} =~ s/^@//) {
            $tmpl = replace_list_var($tmpl, $v, read_list($Opt{var}{$v}));
        }
        else {
            $tmpl =~ s/\Q$Opt{openbrace}$v$Opt{closebrace}\E/$Opt{var}{$v}/g;
        }
        $tmpl =~ s/^#=\s*$v\s*:.*\n//mg;
    }
    print $OutFh $tmpl;
}

sub write_sql {
    my ($sql) = @_;
    if ($Opt{prefix_sql}) {
        $sql =~ s/^/$Opt{prefix_sql}/mg;
        my @t = localtime();
        printf $OutFh "$Opt{prefix_sql}/* Query executed at "
            . "%d-%02d-%02d %d:%02d:%02d in realm '%s' */\n",
            $t[5]+1900, $t[4]+1, $t[3], $t[2], $t[1], $t[0],
            $Opt{dbc_realm} || $DEFAULT_REALM;
    }
    if ($Opt{strip_comments}) {
        $sql =~ s{/\*.*\*/}{}xismg;
    }
    print $OutFh $sql;
}

sub write_results {
    my ($sql, $ofile) = @_;
    my $dbh = $Dbc->connect();
    $dbh->{PrintError} = 0;
    $dbh->{RaiseError} = 1;
    $dbh->{ShowErrorStatement} = 1;
    $dbh->{FetchHashKeyName} = $Opt{lowercase} ? 'NAME_lc' : 'NAME';
    $dbh->{mysql_use_result} = 1;
    if ($Opt{debug} > 1) {
        $sql =~ s/^\s*create.*?view\s+\w+\s+(?:\([^\)]*\)\s+)?as//is;
        $sql =~ s/^\s*select/explain select/i;
    }
    my $sth = $dbh->prepare($sql);
    $sth->execute();
    my $ra_cols = $Opt{lowercase} ? $sth->{NAME_lc} : $sth->{NAME};
    if ($ra_cols) { # non-select statements may not have output columns
        column_formats_from_options($ra_cols);
		$Opt{plain} || print $OutFh join($Opt{delimiter}, @$ra_cols), "\n";
        my $ra;
        while ($ra = $sth->fetchrow_arrayref()) {
            print $OutFh join($Opt{delimiter}, 
                    map { format_value($ra->[$_], $_) } (0..(@$ra_cols-1))
                    ), "\n";
        }
    }
}

sub format_value {
    my ($val, $col) = @_;
    if (!defined $val) {
        return $Opt{null};
    }
    elsif ($ColumnFormat[$col] && $ColumnFormat[$col] =~ /s$/) {
        return sprintf($ColumnFormat[$col], $val);
    }
    elsif ($val =~ /^[0-9.eE+-]+$/) {
        if ($ColumnFormat[$col]) {
            return sprintf($ColumnFormat[$col], $val);
        }
        elsif ($Opt{default_format}) {
            return sprintf($Opt{default_format}, $val);
        }
    }
    return $val;
}

sub column_formats_from_query {
    my ($fields) = @_;
    # try to avoid problems with functions with embedded columns
    my $no_func = $EMPTY;
    while ($fields) {
        if ($fields =~ m/^([^\(]+)/) {
            $no_func .= $1;
            $fields =~ s/^([^\(]+)//;
        }
        extract_bracketed($fields, q{()'"});
    }
    my @fields = split $COMMA, $no_func;
    $ColumnCount = @fields;
    for (my $i = 0; $i < @fields; ++$i) {
        if ($fields[$i] =~ m{/\*\s*
                             $FORMAT_REGEX
                             \s*\*/
                             }xism) {
            $ColumnFormat[$i] = $1;
        }
    }
}

sub column_formats_from_options {
    my ($ra_cols) = @_;
    if (defined $ColumnCount && @$ra_cols != $ColumnCount) {
        warn << 'END_WARNING';
Warning: Different numbers of columns from parsing query and SQL result;
    column formatting in query definition may not be applied correctly.
END_WARNING
        @ColumnFormat = ();
    }
    for (my $i = 0; $i < @$ra_cols; ++$i) {
        if ($Opt{column_format}{$ra_cols->[$i]}) {
            $ColumnFormat[$i] = $Opt{column_format}{$ra_cols->[$i]};
        }
    }
    if ($Opt{debug}) {
        my %wanted;
        @wanted{@$ra_cols} = ();
        my @not_wanted = grep { !exists $wanted{$_} }
            sort keys %{$Opt{column_format}};
        if (@not_wanted) {
            warn "Formats specified for unrecognized columns: '"
                . join($COMMA, @not_wanted) . "'\n";
        }
    }
}

# List vars allowed only in from/where clauses in constructions using
# simple equality, where substituted value is on right side of =
# Code below does not specify from/where clause, but we don't expect
# that equals appears anywhere else in common queries.  A possible exception
# is in column specs where "count(*) = FieldName" is valid in many SQL
# dialects.  TODO: distinguish column list from from/where clauses
sub replace_list_var {
    my ($sql, $v, $ra_values) = @_;
    my $delim = $EMPTY;
    if ($sql =~ /(?<![<>])\s*=\s*(['"]?)
            \Q$Opt{openbrace}$v$Opt{closebrace}\E
            \1/xs) {
        $delim = $1;
    }
    my $list_cond = ' in (' . join($COMMA, map { $delim.$_.$delim }
                @$ra_values) . ') ';
    $sql =~ s{(?<![<>!])                # negative look-behind
              \s*=\s*(['"]?)            # assignment, opt. quotes
              \Q$Opt{openbrace}$v$Opt{closebrace}\E
              \1\s*                     # end quote
             }{$list_cond}xsg;

    if ($sql =~ /(.{0,30}\Q$Opt{openbrace}$v$Opt{closebrace}\E.{0,30})/) {
        warn << "END_WARNING";
Warning! Attempting to replace parameter '$v' with a list,
but parameter appears in query in a form that will not accept a list:
  $1

Please rewrite query to use expected syntax for list-replaceable variables:
     expression = $Opt{openbrace}$v$Opt{closebrace}
  OR expression = '$Opt{openbrace}$v$Opt{closebrace}'

Alternatively, do not try to replace this variable with a list; instead run the
query multiple times, once for each value in the list.

END_WARNING
        if (!$Opt{noexecute}) {
            warn "The results of running this query as it currently stands "
                . "will NOT be valid\n";
        }
    }
    return $sql;
}

sub find_file {
    my ($name) = @_;
    if (-f $name) {
        return $name;
    }
    my (undef, $path) = File::Spec->splitpath($name);
    if ($path) {
        die "File '$name' does not exist\n";
    }
    my @dirs = split /:/, $Opt{path};
    if (!in_list('.', @dirs)) {
        unshift @dirs, '.';
    }
    for my $d (@dirs) {
        my @exts = split /\|/, $Opt{extension};
        for my $ext ($EMPTY, @exts) {
            $ext = ".$ext" if $ext;
            my $file = File::Spec->join($d, $name.$ext);
            if (-f $file) {
                return $file;
            }
        }
    }
    file_not_found_error("Could not find query named '$name'.")
}

sub in_list {
    my $i = shift;
    my $in = 0;
    for my $v (@_) {
        if ($i eq $v) {
            $in = 1;
            last;
        }
    }
    return $in;
}

sub list_queries {
    my $found;
    if ($Opt{path}) {
        my @cols = split /[,:]/, $Opt{list};
        if (!@cols) {
            @cols = qw(query title);
        }
        print join($Opt{delimiter}, @cols), "\n";
        my @dirs = split /:/, $Opt{path};
        for my $d (@dirs) {
            opendir DIR, $d or next;
            my @files = grep { /\.($Opt{extension})$/ } readdir(DIR);
            for my $f (@files) {
                my %info = get_info($d,$f);
                $f =~ s/\.($Opt{extension})$//;
                $info{query} = $f;
                $info{dir} = $d;
                print join($Opt{delimiter}, map { $info{$_}||$EMPTY } @cols),
                    "\n";
                ++$found;
            }
        }
    }
    if (!$found) {
        file_not_found_error("No matching query files found.")
    }
}

sub file_not_found_error {
    my ($msg)  = @_;
    die "$msg\n"
        . "Use --path to indicate directories that contain query files "
        . "(currently\n'$Opt{path}').\nUse --extension to specify query "
        . "file extensions (currently '$Opt{extension}')\n";
}

sub get_info {
    my ($d, $f) = @_;
    my $file = File::Spec->join($d, $f);
    my %info;
    if ( open QFILE, $file ) {
        while (<QFILE>) {
            if (/^##\s*([^:\s]+)\s*:\s*(.*)/) {
                $info{lc $1} = $2;
            }
        }
    }
    return %info;
}

sub process_commandline {
    %Opt = (closebrace  => '}',
            debug       => 0,
            delimiter   => "\t",
            extension   => 'psql',
            null        => $EMPTY,
            openbrace   => '{',
            output      => '-',
            path        => $DEFAULT_SEARCH_PATH,
            prefix_sql  => $EMPTY,
            var         => {},
            );
    GetOptions(\%Opt, qw(closebrace=s
                dbc_realm|realm=s debug+ defaults delimiter=s
                extension=s format=s limit=i list|l:s lowercase|lc
                manual noexecute|n null=s openbrace=s output|o=s
                path=s plain prefix_sql=s region|r=s
                sql strip_comments template var|v=s
                help version)
            ) || pod2usage(0);
    if ($Opt{manual})  { pod2usage(verbose => 2); }
    if ($Opt{help})    { pod2usage(0); }
    if ($Opt{version}) { die "pquery.plx, ", q$Revision: 1.1 $, "\n"; }
    if (defined $Opt{list}) {
        list_queries();
        exit;
    }
    pod2usage("One and only one query file must be provided") if @ARGV != 1;
    if ($Opt{format}) {
        my @f = split /[,:]/, $Opt{format};
        my $err = 0;
        for my $fmt (@f) {
            if ($fmt =~ /^(\w+)=($FORMAT_REGEX)$/) {
                $Opt{column_format}{$1} = $2;
            }
            elsif ($fmt =~ /^$FORMAT_REGEX$/) {
                $Opt{default_format} = $fmt;
            }
            else {
                warn "format '$fmt' not understood\n";
                $err = 1;
            }
        }
        die "\n" if $err;
    }
    if ($Opt{region}) {
        if ($Opt{region} =~ /^$ANY$/i) {
            for my $v (qw(Chr Chrom ChrStart ChrEnd)) {
                $Opt{var}{$v} = $ANY;
            }
        }
        elsif ($Opt{region} =~ /^(?:chr)?((?:\d+|X|Y|XY|M)(?:_random)?) # chrom
                            (?::([0-9,.]+[km]?b?)    # start
                             (?:-([0-9,.]+[km]?b?))? # end
                             )?$/xi) {
            $Opt{var}{Chr} = $1;
            $Opt{var}{Chrom} = "chr$1";
            my ($start,$end) = ($2,$3);
            if ($Opt{var}{Chr} !~ /^\d+$/) {
                $Opt{var}{Chr} = {
                    X   => 23,
                    Y   => 24,
                    M   => 25,
                    XY  => 26,
                }->{$Opt{var}{Chr}};
            }
            if (defined $start) {
                $start =~ s/$COMMA//g;
                if (!defined $end) {
                    $end = $start;
                }
                else {
                    $end =~ s/$COMMA//g;
                }
                $Opt{var}{ChrStart} = $start;
                $Opt{var}{ChrEnd}   = $end;
            }
            else {
                $Opt{var}{ChrStart} = $ANY;
                $Opt{var}{ChrEnd}   = $ANY;
            }
        }
        else {
            pod2usage("Did not understand region spec '$Opt{region}'; "
                    . "should be chrom:start-end\n");
        }
    }
    $OutFh = IO::File->new(">$Opt{output}");
    if ($Opt{sql} && !$Opt{noexecute}) {
        $Opt{prefix_sql} ||= "# ";
    }
    if ($Opt{template}) {
        $Opt{noexecute} = 1;
    }
    if ($Opt{noexecute}) {
        $Opt{sql} = 1;
    }
    else {
        # Doing this here allows us to fail quickly if realm is wrong
        $Dbc = NHGRI::Db::Connector->new(
                realm => $Opt{dbc_realm} || $DEFAULT_REALM );
    }
}

=head1 OPTIONS

=over 4

=item B<--dbc_realm> realm

=item B<--realm>     realm

Specify a realm to use; defaults to 'results' or the DefaultDb referenced in
the psql file header.  See L<FILES>.

=item B<--debug>

Output additional information, including variable names (perhaps useful for
constructing shell scripts or new query templates).  When C<--debug> is
applied twice, select queries will be explain-ed, rather than executed (this
feature only works with MySQL).

=item B<--defaults>

Use defaults, rather than asking user for any information.  Note that if
there are any parameters that do not have default values, and whose values
are not specified on the command line (see C<--var> below), a fatal error
will result.

=item B<--delimiter> CHAR

Specify the delimiter to use between columns.  Defaults to TAB (ASCII 9); a
comma would be another good choice.  To retain sanity, choose something not
contained in your data.

=item B<--extension> EXT

=item B<--extension> 'EXT1|EXT2'

Specify extension of query files, for use when searching.  Defaults to
'psql', so files named 'XXX.psql' are expected.  Extensions are used when the
C<--list> option is used, and when the query name specified does not match a
filename.

=item B<--format> %.3f

=item B<--format> %.3f,p_mul=%.4e

Choose sprintf-style format for output.  A default format may be provided for
all columns, and/or specific formats can be applied to individual columns.
All format declarations must begin with the percent sign, as shown above.
Column specific formats have precedence over the default and over formats
that are specified in the query.  Formats specified in the query have
precedence over the default format.  See L<Column Formatting> for information
about how to specify formatting in the query itself.

=item B<--limit> N

Limit output to the first N lines.

=item B<--list>

=item B<--list> field1,field2

List all available queries.  If field names are provided, the specified
information will be extracted from each file.  If no fields are specified,
'query' (the name of the query) and 'title' (a short description) will be
reported.  All fields should be specified in lowercase.

=item B<--lowercase>

When this option is applied, all column names will be returned in lowercase,
and should be addressed that way, e.g. in the C<--format> option.
Otherwise, column names will be in whatever case is returned from the
DBMS, which may or may not be the case specified in the query.

=item B<--noexecute>

Do not run query, just show the SQL that is produced.

=item B<--null> NULL

Specify string to be output when value is null.  Defaults to blank (empty)
string.  

=item B<--output> FILENAME

Send output to the specified file.  Defaults to STDOUT.

=item B<--path> DIR1:DIR2

Specify paths to be searched.

=item B<--plain>

Omit the header line when returning results.

=item B<--region> chrom:start-end

=item B<--region> ANY

Specify a region on a chromosome, bounded by a start and end position.
The special value 'ANY' replaces all instances of variables Chr, Chrom,
ChrStart and ChrEnd with 'ANY', making the query apply to all regions
across the entire genome (note this can result in long run times and/or
large result sets).  See L<Excludable Conditions>.

=item B<--sql>

Prepend fully parsed SQL to the output.  This may be done in
addition to running the query, or instead of running the query (if
C<--noexec> is specified).  If the SQL is written in addition to the results
of the query, the SQL will be commented out using a hash (#) prefix; when
C<--noexec> is specified, the SQL statement will not have a prefix.

=item B<--strip_comments>

Strip all C-style comments out of SQL, for database engines that don't
support this type of comment.  By default, C-style comments, including the
specialized ones that pquery.plx uses for formatting, are retained.

=item B<--template>

Return the pquery template.  This is useful when you want to modify an
existing pquery template to make a new one.  Templates are returned verbatim,
except that variables specified with the C<--var> option are substituted,
optionally creating a pquery with fewer variables.

=item B<--var> VariableName=VALUE[,VALUE2...]

=item B<--var> VariableName=@FILENAME

=item B<-v>    VariableName=VALUE

Pre-specify values for a variable, so that the program does not prompt you
for them.  May be used multiple times to set several variables, e.g.

    pquery -v MaxPval=.001 -v Table=t2d_s1_typed_v query.psql

Often used in combination with C<--defaults>, to leave other variables
unchanged, or with C<--template>, to create a template with fewer parameters.

Note that certain variables may be replaced with multiple values, either read
from a file where each value is listed on a separate line, or specified in a
comma-delimited list.  See L<List-Replaceable Parameters> for more details.
For such list-replaceable variables, you may specify a path to a file to read
by prefixing it with an C<@> symbol:

    pquery -v SnpName=@/path/to/filename.list query.psql

Or simply enumerate the values, separating them with a comma:

    pquery -v "SnpName=value1,value2" query.psql

Note that you must use quotes around the entire variable assignment, as shown
above, if any of the values contain spaces.

=item B<--help>

Display basic usage information.

=item B<--manual>

Display complete documentation, including all options.

=back

=head1 FILES

The parameterized SQL query files that this script reads are a variation on
regular SQL, therefore, in the simple case, a file containing an ordinary SQL
query will work.  The real power of this program, however, comes from
replaceable parameters, and to a lesser extent, descriptive headers and
column formats.

At this point, the query files must contain a single SQL statement, but this
limitation may be removed in future versions.

=head2 Replaceable Parameters (placeholders)

Query files typically have a '.psql' extension because they are
'Parameterized SQL' files.  The format calls for replaceable parameters to be
identified by surrounding the placeholder name with curly brackets, e.g.

    select count(*) from my_table where rsquare > {CutoffValue}

Any part of the query may be replaced by a placeholder, including table and
column names.  When this is done, it is best to use an alias to allow the
rest of the query (including the output field names) to stay the same:

    select snp, {PvalueField} as p_val
      from {AssociationTable} t
           inner join snp_pos p on (p.snp = t.snp)
     where t.trait = "{Trait}"
     order by {PvalueField}
     limit 10;

As you see in the above example, placeholders may also be used within quoted
strings (indeed, must be, when the value needs to be quoted).  At the moment,
there is no way to escape the curly brackets to allow literal brackets to be
included as part of a query, but since these characters are rarely used, this
should not present much of a problem.  A future version of this program may
resolve this issue.

=head2 List-Replaceable Parameters

As a special case, certain parameters are allowed to take on multiple values,
any one of which will satisfy the query.  This is useful, for example, if you
want to obtain query results for several different values, without running
the query separately for each value.

In order to qualify as a list-repleaceable parameter, the parameter must be
used only on the right hand side of an equality condition, such as

    expression = {VariableName}  OR  expression = "{VariableName}"

The variable may appear in this type of expression more than once, but cannot
appear any other way in the query.  For example, the SQL expression

    t.trait = "{Trait}"

in the query above qualifies C<Trait> as a list-replaceable parameter.  For
such list-replaceable variables, you may either specify the list values by
separating them with commas, or specify a path to a file to read by prefixing
it with an C<@> symbol.  You may use either approach, both in a C<--var>
option on the commandline, or in answer to an interactive prompt.  

For example, if the query above were run with the following commandline:

    pquery -v Trait=hdl,ldl,sbp query.psql

The SQL code generated would replace the condition above with an C<in> clause:

    t.trait in ("hdl","ldl","sbp")

The same results would be achieved if the query above were run with the
following commandline:

    pquery -v Trait=@/path/to/trait.list query.psql

And /path/to/trait.list was a readable file with three lines:

    hdl
    ldl
    sbp

Note that lines beginning with C<#> characters in a list file are considered
comments, and will be ignored.  Every other line becomes a value of the C<in>
clause.

Note that most databases impose a limit on the length of a submitted query;
very long lists may exceed this limit.  For such long lists, a better approach
is to load the list of values into a table and join this table with other
tables of interest.

=head2 Excludable Conditions

If a variable is assigned the special value 'ANY', whether interactively, on
the commandline, or by default, pquery will attempt to remove conditions
involving this variable from the query, thereby allowing all values of the
associated column.  In order for this to work, the condition must be
specified as

    [table.]column_name <operator> {Variable}

Where operator can be any of the standard tests for (in-)equality: "=, !=,
<>, <, <=, >, >=", and where the variable may be enclosed in single or double
quotes.  To remove the conditions from the query, each is replaced by the
always-true condition C<1=>.

=head2 Descriptive Headers

All lines that begin with a hash mark (#) in the first column are comments.
Comments may appear on any line (not just at the beginning of the file,
though this is standard), but the hash mark must always be the first
character on the line.  Some of these comments have special meaning to the
parsing script, as described below:

B<MetaData>: Lines that begin with two hash marks (##) are used to specify
key/value pairs.  You may define as many different keys as you like, but
several of these keys are well-known and expected to be provided, including
'title', 'author', and 'requestor'.  Names are case-insensitive.  For now,
all lines that begin with two hash marks are echoed to the user when the
file is parsed; this behavior may change in the future.  For example:

    ## Title: Find QT trends supported by T2D assoc in same gene
    ## Author: Peter Chines
    ## $Date: 2008/08/08 16:46:34 $

One special metadata header is C<DefaultDb>.  This header specifies the
database realm to use to run the query, in the absence of an explicit
commandline parameter (C<--db_realm>).  For example:

    ## DefaultDb: annotation

B<Variable Definition>: Lines that begin with a hash mark followed by a
equals sign (#=) define placeholder variable prompts and (optionally) default
values.

    #= PvalueField: p-value field to use [p_mul]

This will result in the following prompt:

    p-value field to use? [p_mul]

This indicates that the default value 'p_mul' will be used if the user simply
presses return.  It is always a good idea to provide a default value, both to
allow the query to be used more easily, and to indicate, in a very succinct
way, the type of data that is required.

In the absence of a variable definition line, prompts are much less
descriptive, and no default is provided, e.g.

    PvalueField?

Note that under debug mode, these prompts are different; see
L<DEBUGGING QUERIES>.

Variable definitions that begin with a hash mark followed by a colon (#:) are
similar, except that these variables are declared by the query author to be
non-list-replacable and non-excludable (see L<List-Replaceable Parameters> and
L<Excludable Conditions>, above).  Thus, the special treatment for commas and
for the value 'ANY' will not apply to such variables.  Unless you expect your
data columns to contain commas or the value 'ANY', it is generally not 
desirable to use the "#:" declaration; use "#=" instead.

=head2 Column Formatting

As an additional feature, pquery.plx also allows sprintf-style formats to be
specified for individual columns of the query.  These formats may be embedded
in the input query, as described here, or specified on the command line (see
C<--format> option, below).

    select snp, p_mul /* %.5f */, or_mul as odds_ratio
      from {ResultsTable}
     where p_mul <= {PvalCutoff}
     order by p_mul

This would cause the p_mul field to be formatted with 5 decimal digits.  Most
database engines will ignore C-style comments like these.  For those that do
not, you can use the C<--strip_comments> option to remove them prior to
executing (or outputting) the query.

=head1 ENVIRONMENT VARIABLES

B<PQUERY_PATH> is a colon-delimited list of directories to search for pquery
files (C<*.psql>).  If this variable is not set, a default set of paths will
be used, which typically includes the current working directory, as well as
C<~/pquery> in the user's home directory.

=head1 DEBUGGING QUERIES

Currently, two levels of debugging are available; specifying C<--debug> once
or twice determines the level of debugging activated.  These debug modes are
intended to be useful both for query authors and for those who wish to use
parameterized queries in scripts.

=head2 Debug Mode 1

In debug mode, warnings are issued for:

=over 4

=item Parameter variables defined, but not used

=item Parameters used, but not defined

=item Parameters with no default value

=back

In addition parameter prompts in Debug mode include the actual names of the
parameters, e.g. this parameter definition

    #= PvalueField: p-value field to use [p_mul]

will result in the following prompt:

    p-value field to use? [PvalueField=p_mul]

Where no default value is provided, the parameter name still appears:

    p-value field to use? [PvalueField=]

=head2 Debug Mode 2

In addition to all of the features described for Debug Mode 1, in this mode,
MySQL SELECT queries (and CREATE VIEW queries) are not actually executed.
Instead, pquery issues an "explain" query, so that the results are the query
plan.  This is a good way to check queries that run much slower than you
think they should (assuming that you know how to interpret the output).

In the future, this functionality may be extended to other DBMS, but for now,
this works only with MySQL.

=head1 TODO

=over 4

=item * Separate query-user documentation from query-author documentation?

=item * Add support for "not in" queries

On the same model as for list-replaceable parameters, except recognizing <> and
!=, rather than simple equality.  Also, consider recognizing "in ()" lists
directly and populating them.

=item * Should List-Replaceable Parameters be specially recognized?

--debug mode could identify variables that are list-replaceable; what is best
way to do this?

=item * Allow multiple statements in query file

Use semicolon as command separator, but hard part is determining whether it
is in a quoted literal.

=item * Provide escapes for literal curly braces

Backslash is one obvious possibility.  Another is doubling.  Can implement
these with negative lookbehind regexp C<(?<!\\)>?

=item * Some parameters should be limited to selection from a list

This could be a different type of variable definition C<#:>, perhaps with
an embedded query to extract choices from database?

=item * Allow parameter value to trigger inclusion of more SQL

This could be used to have optional SQL statements, or to implement several
alternative join conditions, rather than having several separate psql files.

=item * Prompts can't contain '[' and defaults can't contain ']'

This might be worth worrying about, someday.

=back

=head1 AUTHOR

 Peter Chines - pchines@mail.nih.gov

 based on many ideas and suggestions by Randall Pruim - rpruim@calvin.edu

=head1 LEGAL

This software/database is "United States Government Work" under the terms of
the United States Copyright Act.  It was written as part of the authors'
official duties for the United States Government and thus cannot be
copyrighted.  This software/database is freely available to the public for
use without a copyright notice.  Restrictions cannot be placed on its present
or future use. 

Although all reasonable efforts have been taken to ensure the accuracy and
reliability of the software and data, the National Human Genome Research
Institute (NHGRI) and the U.S. Government does not and cannot warrant the
performance or results that may be obtained by using this software or data.
NHGRI and the U.S.  Government disclaims all warranties as to performance,
merchantability or fitness for any particular purpose. 

In any work or product derived from this material, proper attribution of the
authors as the source of the software or data should be made, using "NHGRI
FUSION Research Group" as the citation. 

=cut
