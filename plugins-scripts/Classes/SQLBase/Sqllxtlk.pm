package Classes::SQLBase::Sqllxtlk;
our @ISA = qw(Classes::SQLBase);
use strict;
use Time::HiRes;
use File::Basename;
use File::Temp qw(tempfile);

sub create_cmd_line {
  my $self = shift;
  my @args = ();
  push (@args, "BAT");
  push (@args, "NOCONNECT");
  push (@args, sprintf "INI='%s'",
      $Monitoring::GLPlugin::DB::sql_inifile);
  push (@args, sprintf "INPUT='%s'",
      $Monitoring::GLPlugin::DB::sql_commandfile);
  push (@args, sprintf "OUTPUT='%s'",
      $Monitoring::GLPlugin::DB::sql_resultfile);
  $Monitoring::GLPlugin::DB::session =
      sprintf '"%s" %s', $self->{extcmd}, join(" ", @args);
}

sub check_connect {
  my $self = shift;
  my $stderrvar;
  if ($ENV{SQLBASE}) {
    $ENV{PATH} .= ':'.$ENV{SQLBASE};
    $ENV{LD_LIBRARY_PATH} .= ':'.$ENV{SQLBASE};
  }
  if (! $self->find_extcmd("sqllxtlk", "SQLBASE")) {
    $self->add_unknown("sqllxtlk command was not found");
    return;
  }
  $self->create_extcmd_files();
  $self->create_cmd_line();
  eval {
    $self->set_timeout_alarm($self->opts->timeout - 1, sub {
      die "alrm";
    });
    *SAVEERR = *STDERR;
    open OUT ,'>',\$stderrvar;
    *STDERR = *OUT;
    $self->{tic} = Time::HiRes::time();
    my $answer = $self->fetchrow_array(q{
        SELECT COUNT(*) from SYSSQL.SYSTABLES
    });
# TRANSACTION COMMITTED
# oder bei sqllxtlk noconnect
# Error: 05163 TLK NCN No CONNECTs done yet: this command requires a database connection
    die 'connection failed' unless defined $answer and $answer =~ /\d+$/;
    $self->{tac} = Time::HiRes::time();
    *STDERR = *SAVEERR;
  };
  if ($@) {
    if ($@ =~ /alrm/) {
      $self->add_critical(
          sprintf "connection could not be established within %s seconds",
          $self->opts->timeout);
    } elsif ($@ =~ /connection failed/) {
      $self->add_critical('connection could not be established');
    } else {
      $self->add_critical($@);
    }
  } elsif ($stderrvar) {
    $self->add_critical($stderrvar);
  } else {
    $self->set_timeout_alarm($self->opts->timeout - ($self->{tac} - $self->{tic}));
  }
}

sub create_extcmd_files {
  my ($self) = @_;
  $self->SUPER::create_extcmd_files();
  my $template = $self->opts->mode.'XXXXX';
  if ($^O =~ /MSWin/) {
    $template =~ s/::/_/g;
  }
  ($self->{sql_inifile_handle}, $self->{sql_inifile}) =
      tempfile($template, SUFFIX => ".ini",
      DIR => $self->system_tmpdir() );
  close $self->{sql_inifile_handle};
  $Monitoring::GLPlugin::DB::sql_inifile = $self->{sql_inifile};
}

sub delete_extcmd_files {
  my ($self) = @_;
  $self->SUPER::delete_extcmd_files();
  unlink $Monitoring::GLPlugin::DB::sql_inifile
      if $Monitoring::GLPlugin::DB::sql_inifile &&
      -f $Monitoring::GLPlugin::DB::sql_inifile;
}

sub write_extcmd_file {
  my $self = shift;
  my $sql = shift;
  $sql =~ s/;$//g;
  open CMDCMD, "> $Monitoring::GLPlugin::DB::sql_commandfile";
  printf CMDCMD "SET ECHO OFF;\n";
  if ($self->opts->commit) {
    printf CMDCMD "SET AUTOCOMMIT ON\n";
  }
  printf CMDCMD "SET NULLS '__NULL__';\n";
  printf CMDCMD "SET SPACE 5;\n";
  printf CMDCMD "SET PAUSE OFF;\n";
  #printf CMDCMD "SET HEADING OFF;\n";
  printf CMDCMD "SET PAGESIZE 99999;\n";
  printf CMDCMD "SET SPOOL OUTPUT.TXT OVERWRITE;\n";
  printf CMDCMD "CONNECT %s 1 %s/%s/%s;\n",
      $self->opts->database,
      $self->opts->username,
      $self->decode_rfc3986($self->opts->password),
      $self->opts->server;
  printf CMDCMD "SET ERRORLEVEL 2;\n";
  printf CMDCMD "SET LINESIZE 5000;\n";
  printf CMDCMD "%s;\n", $sql;
  printf CMDCMD "DISCONNECT ALL;\n";
  close CMDCMD;
  open CMDINI, "> $Monitoring::GLPlugin::DB::sql_inifile";
  printf CMDINI "[linuxclient]\n";
  printf CMDINI "clientname=localhost\n";
  printf CMDINI "clientruntimedir=%s\n", $ENV{SQLBASE};
  printf CMDINI "[linuxclient.tcpip]\n";
  printf CMDINI "serverpath=%s,%s,%s/*\n",
      $self->opts->server,
      $self->opts->hostname,
      $self->opts->port;
  close CMDINI;
}

sub fetchrow_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my @row = ();
  my $stderrvar = "";
  foreach (@arguments) {
    # replace the ? by the parameters
    if (/^\d+$/) {
      $sql =~ s/\?/$_/;
    } else {
      $sql =~ s/\?/'$_'/;
    }
  }
  $self->set_variable("verbosity", 2);
  $self->debug(sprintf "SQL (? resolved):\n%s\nARGS:\n%s\n",
      $sql, Data::Dumper::Dumper(\@arguments));
  $self->write_extcmd_file($sql);
  *SAVEERR = *STDERR;
  open OUT ,'>',\$stderrvar;
  *STDERR = *OUT;
  $self->debug($Monitoring::GLPlugin::DB::session);
  my $exit_output = `$Monitoring::GLPlugin::DB::session`;
  *STDERR = *SAVEERR;
  if ($?) {
    my $output = do { local (@ARGV, $/) = $Monitoring::GLPlugin::DB::sql_resultfile; my $x = <>; close ARGV; $x } || '';
    $self->debug(sprintf "stderr %s", $stderrvar) ;
    $self->debug(sprintf "output %s", $output) ;
    $self->add_warning($stderrvar);
  } else {
    my $output = do { local (@ARGV, $/) = $Monitoring::GLPlugin::DB::sql_resultfile; my $x = <>; close ARGV; $x } || '';
    $self->debug(sprintf "output %s", $output) ;
    my $rowcnt = 0;
    my $inresult = 0;
    my $connected = 0;
    my @rows = ();
    my @resultparts = ();
    foreach my $line (split(/\n/, $output)) {
      chomp $line;
      if ($line =~ /^\s*$/) {
        next;
      } elsif ($line =~ /^[=\s]+$/) {
        $inresult = 1;
        my $pos = 0;
        my $maxpos = length($line) - 1;
        foreach my $part (grep { length($_); } split(/(=+\s*)/, $line)) {
          if ($pos + length($part) > $maxpos) {
            push(@resultparts, [$pos, $maxpos - $pos]);
          } else {
            push(@resultparts, [$pos, length($part)]);
          }
          $pos += length($part);
        }
      } elsif ($line =~ /(\d+) ROWS SELECTED/) {
        $rowcnt = 1;
        $inresult = 0;
      } elsif ($line =~ /CURSOR 1 CONNECTED RO/) {
        $connected = 0;
      } elsif ($inresult) {
        $line =~ s/^\t*//g;
        push(@rows, [map {
          $_ eq '__NULL__' ? undef : $_;
        } map {
            s/\s*$//g; $_;
        } map {
            s/^\s*//g; $_;
        } split(/\t+/, $line)]);
      } else {
      }
    }
    @row = @{$rows[0]};
    $self->debug(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper(\@row));
  }
  return $row[0] unless wantarray;
  return @row;
}

sub fetchall_array {
  my $self = shift;
  my $sql = shift;
  my @arguments = @_;
  my $rows = [];
  my $stderrvar = "";
  foreach (@arguments) {
    # replace the ? by the parameters
    if (/^\d+$/) {
      $sql =~ s/\?/$_/;
    } else {
      $sql =~ s/\?/'$_'/;
    }
  }
  $self->set_variable("verbosity", 2);
  $self->debug(sprintf "SQL (? resolved):\n%s\nARGS:\n%s\n",
      $sql, Data::Dumper::Dumper(\@arguments));
  $self->write_extcmd_file($sql);
  *SAVEERR = *STDERR;
  open OUT ,'>',\$stderrvar;
  *STDERR = *OUT;
  $self->debug($Monitoring::GLPlugin::DB::session);
  my $exit_output = `$Monitoring::GLPlugin::DB::session`;
  *STDERR = *SAVEERR;
  if ($?) {
    my $output = do { local (@ARGV, $/) = $Monitoring::GLPlugin::DB::sql_resultfile; my $x = <>; close ARGV; $x } || '';
    $self->debug(sprintf "stderr %s", $stderrvar) ;
    $self->debug(sprintf "output %s", $output) ;
    $self->add_warning($stderrvar);
  } else {
    my $output = do { local (@ARGV, $/) = $Monitoring::GLPlugin::DB::sql_resultfile; my $x = <>; close ARGV; $x } || '';
    $self->debug(sprintf "output %s", $output) ;
    my $rowcnt = 0;
    my $inresult = 0;
    my $connected = 0;
    my @rows = ();
    my @resultparts = ();
    foreach my $line (split(/\n/, $output)) {
      chomp $line;
      if ($line =~ /^\s*$/) {
        next;
      } elsif ($line =~ /^[=\s]+$/) {
        $inresult = 1;
        my $pos = 0;
        my $maxpos = length($line) - 1;
        foreach my $part (grep { length($_); } split(/(=+\s*)/, $line)) {
          if ($pos + length($part) > $maxpos) {
            push(@resultparts, [$pos, $maxpos - $pos]);
          } else {
            push(@resultparts, [$pos, length($part)]);
          }
          $pos += length($part);
        }
      } elsif ($line =~ /(\d+) ROWS SELECTED/) {
        $rowcnt = 1;
        $inresult = 0;
      } elsif ($line =~ /CURSOR 1 CONNECTED RO/) {
        $connected = 0;
      } elsif ($inresult) {
        $line =~ s/^\t*//g;
        push(@rows, [map {
          $_ eq '__NULL__' ? undef : $_;
        } map {
            s/\s*$//g; $_;
        } map {
            s/^\s*//g; $_;
        } split(/\t+/, $line)]);
      } else {
      }
    }
    $rows = \@rows;
    $self->debug(sprintf "RESULT:\n%s\n",
        Data::Dumper::Dumper($rows));
  }
  return @{$rows};
}

sub decode_rfc3986 {
  my $self = shift;
  my $password = shift;
  eval {
    no warnings 'all';
    $password = $Monitoring::GLPlugin::plugin->{opts}->decode_rfc3986($password);
  };
  return $password;
}

sub add_dbi_funcs {
  my $self = shift;
  {
    no strict 'refs';
    *{'Monitoring::GLPlugin::DB::create_cmd_line'} = \&{"Classes::SQLBase::Sqllxtlk::create_cmd_line"};
    *{'Monitoring::GLPlugin::DB::write_extcmd_file'} = \&{"Classes::SQLBase::Sqllxtlk::write_extcmd_file"};
    *{'Monitoring::GLPlugin::DB::fetchall_array'} = \&{"Classes::SQLBase::Sqllxtlk::fetchall_array"};
    *{'Monitoring::GLPlugin::DB::fetchrow_array'} = \&{"Classes::SQLBase::Sqllxtlk::fetchrow_array"};
    *{'Monitoring::GLPlugin::DB::execute'} = \&{"Classes::SQLBase::Sqllxtlk::execute"};
    # because we don't have Classes::SQLBase::init. Otherwise we would end up
    # in Classes::Device::init which reblesses us to Monitoring::GLPlugin::DB
    *{'Classes::SQLBase::Sqllxtlk::init'} = \&{"Monitoring::GLPlugin::DB::init"};
  }
}

