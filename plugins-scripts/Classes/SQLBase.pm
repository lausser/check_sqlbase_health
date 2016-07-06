package Classes::SQLBase;
our @ISA = qw(Classes::Device);

sub init {
  my $self = shift;
  if ($self->mode =~ /^server::_placeholder_/) {
  } else {
    $self->no_such_mode();
  }
}


