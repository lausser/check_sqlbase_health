#! /usr/bin/perl

use strict;

eval {
  if ( ! grep /AUTOLOAD/, keys %Monitoring::GLPlugin::) {
    require Monitoring::GLPlugin;
    require Monitoring::GLPlugin::DB;
  }
};
if ($@) {
  printf "UNKNOWN - module Monitoring::GLPlugin was not found. Either build a standalone version of this plugin or set PERL5LIB\n";
  printf "%s\n", $@;
  exit 3;
}

my $plugin = Classes::Device->new(
    shortname => '',
    usage => '%s [-v] [-t <timeout>] '.
        '--hostname=<db server hostname> [--port <port>] '.
        '--username=<username> --password=<password> '.
        '--mode=<mode> '.
        '...',
    version => '$Revision: #PACKAGE_VERSION# $',
    blurb => 'This plugin checks SQLBase (Gupta) database servers ',
    url => 'http://labs.consol.de/nagios/check_sqlbase_health',
    timeout => 60,
);
$plugin->add_db_modes();
$plugin->add_db_args();
$plugin->add_default_args();
$plugin->mod_arg('method',
    default => 'sqlbase',
);
$plugin->add_arg(
    spec => 'server=s',
    help => "--server
   the database server",
    required => 0,
);
$plugin->add_arg(
    spec => 'hostname=s',
    help => "--hostname
   the database server",
    required => 0,
);
$plugin->add_arg(
    spec => 'username=s',
    help => "--username
   the mssql user",
    required => 0,
);
$plugin->add_arg(
    spec => 'password=s',
    help => "--password
   the mssql user's password",
    required => 0,
    decode => "rfc3986",
);
$plugin->add_arg(
    spec => 'port=i',
    default => 2155,
    help => "--port
   the database server's port",
    required => 0,
);
$plugin->add_arg(
    spec => 'database=s',
    help => "--database
   the database the plugin should connect",
    required => 1,
);

$plugin->getopts();
$plugin->classify();
$plugin->validate_args();


if (! $plugin->check_messages()) {
  $plugin->init();
  if (! $plugin->check_messages()) {
    $plugin->add_ok($plugin->get_summary())
        if $plugin->get_summary();
    $plugin->add_ok($plugin->get_extendedinfo(" "))
        if $plugin->get_extendedinfo();
  }
} else {
#  $plugin->add_critical('wrong device');
}
my ($code, $message) = $plugin->opts->multiline ?
    $plugin->check_messages(join => "\n", join_all => ', ') :
    $plugin->check_messages(join => ', ', join_all => ', ');
$message .= sprintf "\n%s\n", $plugin->get_info("\n")
    if $plugin->opts->verbose >= 1;
#printf "%s\n", Data::Dumper::Dumper($plugin);
$plugin->nagios_exit($code, $message);


