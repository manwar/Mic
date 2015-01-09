use strict;
use Test::Lib;
use Test::More;

use Minions
    bind => {
        'Example::Roles::Queue' => 'Example::Roles::Acme::Queue_v2',
    };
use Example::Roles::Queue;

my $q = Example::Roles::Queue->new;

is $q->size => 0;

$q->push(1);
is $q->size => 1;

$q->push(2);
is $q->size => 2;

$q->pop;
is $q->size => 1;
done_testing();