package Scot::Inbox::Msgraph::Cursor;

use lib '../../../../lib';
use strict;
use warnings;
use Moose;

has ids => (
    is => 'rw', isa => 'ArrayRef', traits => ['Array'],
    default => sub {[]}, 
    handles => {
        all_ids => 'elements',
        next_id => 'shift',
    }
);

has env => (
    is  => 'ro', isa => 'Scot::Env', required => 1
);

has msgraph => (
    is => 'rw', isa => 'Scot::Email::MSGraph', required => 1
);

sub count {
    my $self    = shift;
    return scalar(@{$self->ids});
}

sub next {
    my $self    = shift;
    my $id      = $self->next_id;
    if ( ! defined $id ) {
        return undef;
    }
    return $self->msgraph->get_message($id);
}

1;