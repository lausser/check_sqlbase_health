package Classes::Device;
our @ISA = qw(Monitoring::GLPlugin::DB);
use strict;


sub classify {
  my $self = shift;
  if ($self->opts->method eq 'sqlbase') {
    bless $self, "Classes::SQLBase::Sqllxtlk";
    if ((! $self->opts->hostname && ! $self->opts->server) ||
        ! $self->opts->username || ! $self->opts->password) {
      $self->add_unknown('Please specify hostname or server, username and password');
    }
  } else {
    $self->add_unknown('unknown connection method');
  }
  if (! $self->check_messages()) {
    $self->check_connect();
    if (! $self->check_messages()) {
      $self->add_dbi_funcs();
      if ($self->opts->mode =~ /^my-/) {
        $self->load_my_extension();
      }
    }
  }
}

