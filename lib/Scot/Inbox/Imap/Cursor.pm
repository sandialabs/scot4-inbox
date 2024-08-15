package Scot::Inbox::Imap::Cursor;

use lib '../../../../lib';
use strict;
use warnings;
use Moose;

has uids    => (
    is          => 'rw',
    isa         => 'ArrayRef',
    traits      => [ 'Array' ],
    default     => sub { [] },
    handles     => {
        all_uids    => 'elements',
        next_uid    => 'shift',
    }
);

has imap  => (
    is          => 'rw',
    isa         => 'Scot::Inbox::Imap',
    required    => 1,
);


sub count {
    my $self    = shift;
    
    return scalar(@{ $self->uids });
}

sub next {
    my $self    = shift;
    my $uid     = $self->next_uid;

    return $self->imap->get_message($uid);
}

sub all {
    my $self    = shift;
    my @all     = ();

    while ( my $msg = $self->next ) {
        push @all, $msg;
    }
    return wantarray ? @all : \@all;
}

1;
