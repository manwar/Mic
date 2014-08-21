use strict;
use Test::Lib;
use Test::Most;
use Minion;

package FixedSizeQueue;

our %__Meta = (
    interface => [qw(push size max_size)],
    roles => ['FixedSizeQueueRole'],
    has  => {
        max_size => { 
            assert => { positive_int => sub { $_[0] =~ /^\d+$/ && $_[0] > 0 } }, 
            reader => 1,
        },
    }, 
);
Minion->minionize;

package main;

my $q = FixedSizeQueue->new(max_size => 3);

is($q->max_size, 3);

$q->push(1);
is($q->size, 1);

$q->push(2);
is($q->size, 2);

throws_ok { FixedSizeQueue->new() } qr/Assertion failure: max_size is provided/;
throws_ok { FixedSizeQueue->new(max_size => 0) } qr/Assertion failure: max_size is positive_int/;

done_testing();