package Minions::Implementation;

use strict;
use Minions::_Guts;
use Package::Stash;
use Readonly;

sub import {
    my ($class, %arg) = @_;

    strict->import();

    $arg{-caller} = (caller)[0];
    $class->define(%arg);
}

sub define {
    my ($class, %arg) = @_;

    my $caller_pkg = delete $arg{-caller} || (caller)[0];
    my $stash = Package::Stash->new($caller_pkg);

    $class->update_args(\%arg);
    $class->add_attribute_syms(\%arg, $stash);

    $stash->add_symbol('%__meta__', \%arg);
}

sub add_attribute_syms {
    my ($class, $arg, $stash) = @_;

    my @slots = (
        keys %{ $arg->{has} },
        @{ $arg->{requires}{attributes} || [] },
        '', # semiprivate pkg
    );
    foreach my $slot ( @slots ) {
        $class->add_obfu_name($arg, $stash, $slot);
    }
}

sub add_obfu_name {
    my ($class, $arg, $stash, $slot) = @_;

    Readonly my $sym_val => "$Minions::_Guts::attribute_sym-$slot";
    $Minions::_Guts::obfu_name{$slot} = $sym_val;

    $stash->add_symbol(
        sprintf('$%s%s', $arg->{attribute_var_prefix} || '__', $slot),
        \ $sym_val
    );
}

sub update_args {}

1;

__END__

=head1 NAME

Minions::Implementation

=head1 SYNOPSIS

    package Example::Construction::Acme::Set_v1;

    use Minions::Implementation
        has => {
            set => {
                default => sub { {} },
                init_arg => 'items',
                map_init_arg => sub { return { map { $_ => 1 } @{ $_[0] } } },
            }
        },
    ;

    sub has {
        my ($self, $e) = @_;
        exists $self->{$__set}{$e};
    }

    sub add {
        my ($self, $e) = @_;
        ++$self->{$__set}{$e};
    }

    1;

=head1 DESCRIPTION

An implementation is a package containing attribute definitions as well as subroutines implementing the
behaviours described by the class interface.

=head1 CONFIGURATION

An implementation package can be configured either using Minions::Implementation or with a package variable C<%__meta__>. Both methods make use of the following keys:

=head2 has => HASHREF

This declares attributes of the implementation, mapping the name of an attribute to a hash with keys described in
the following sub sections.

An attribute called "foo" can be accessed via it's object in one of two ways:

    # implementation defined using Minions::Implementation
    $self->{$__foo}

    # implementation defined using %__meta__
    $self->{-foo}

The advantage of the first form is that the symbol C<$__foo> is not (easily) available to users of the object, so
there is greater incentive for using the provided interface when using the object.

=head3 default => SCALAR | CODEREF

The default value assigned to the attribute when the object is created. This can be an anonymous sub,
which will be excecuted to build the the default value (this would be needed if the default value is a reference,
to prevent all objects from sharing the same reference).

=head3 assert => HASHREF

This is like the C<assert> declared in a class package, except that these assertions are not run at
construction time. Rather they are invoked by calling the semiprivate ASSERT routine.

=head3 handles => ARRAYREF | HASHREF | SCALAR

This declares that methods can be forwarded from the object to this attribute in one of three ways
described below. These forwarding methods are generated as public methods if they are declared in
the interface, and as semiprivate routines otherwise.

=head3 handles => ARRAYREF

All methods in the given array will be forwarded.

=head3 handles => HASHREF

Method forwarding will be set up such that a method whose name is a key in the given hash will be
forwarded to a method whose name is the corresponding value in the hash.

=for comment
=head3 handles => SCALAR
The scalar is assumed to be a role, and methods provided directly (i.e. not including methods in sub-roles) by the role will be forwarded.

=head3 init_arg => SCALAR

This causes the attribute to be populated with the value of a similarly named constructor parameter.

=head3 map_init_arg => CODEREF

If the attribute has an C<init_arg>, it will be populated with the result of applying the given code ref to the value of a similarly named constructor parameter.

=head3 reader => SCALAR

This can be a string which if present will be the name of a generated reader method.

This can also be the numerical value 1 in which case the generated reader method will have the same name as the key.

Readers should only be created if they are needed by end users of the class.

=head3 writer => SCALAR

This can be a string which if present will be the name of a generated writer method.

This can also be the numerical value 1 in which case the generated writer method will have a name of the form C<change_foo> where "foo" is the given key.

Writers should only be created if they are needed by end users of the class.

=for comment
=head2 semiprivate => ARRAYREF
Any subroutines in this list will be semiprivate, i.e. they will not be callable as regular object methods but
can be called using the syntax:
    $self->{'!'}->do_something(...) 
=head2 roles => ARRAYREF

A reference to an array containing the names of one or more Role packages that define the subroutines declared in the interface.

L<Minions::Role> describes how roles are configured.

=head1 PRIVATE ROUTINES

An implementation package will typically contain subroutines that are for internal use in the package and therefore ought not to be declared in the interface.
These won't be callable using the C<$minion-E<gt>command(...)> syntax.

As an example, suppose we want to print an informational message whenever the Set's C<has> or C<add> methods are called. A first cut may look like:

    sub has {
        my ($self, $e) = @_;

        warn sprintf "[%s] I have %d element(s)\n", scalar(localtime), scalar(keys %{ $self->{$__set} });
        exists $self->{$__set}{$e};
    }

    sub add {
        my ($self, $e) = @_;

        warn sprintf "[%s] I have %d element(s)\n", scalar(localtime), scalar(keys %{ $self->{$__set} });
        ++$self->{$__set}{$e};
    }

But this duplication of code is not good, so we factor it out:

    sub has {
        my ($self, $e) = @_;

        log_info($self);
        exists $self->{$__set}{$e};
    }

    sub add {
        my ($self, $e) = @_;

        log_info($self);
        ++$self->{$__set}{$e};
    }

    sub size {
        my ($self) = @_;
        scalar(keys %{ $self->{$__set} });
    }

    sub log_info {
        my ($self) = @_;

        warn sprintf "[%s] I have %d element(s)\n", scalar(localtime), $self->size;
    }

Notice how the C<log_info> routine is called as a regular sub rather than as a method.

Here is a transcript of using this object via L<reply|https://metacpan.org/pod/distribution/Reply/bin/reply>

    1:54% reply -I t/lib
    0> use Example::Construction::Set_v1
    1> my $set = Example::Construction::Set_v1->new
    $res[0] = bless( {
                '!' => 'Example::Construction::Set_v1::__Private',
                'be93cca1-set' => {}
            }, 'Example::Construction::Set_v1::__Minions'  )

    2> $set->can
    $res[1] = [
      'add',
      'has'
    ]

    3> $set->add(1)
    [Thu Jan  1 13:56:47 2015] I have 0 element(s)
    $res[2] = 1

    4> $set->add(1)
    [Thu Jan  1 13:56:51 2015] I have 1 element(s)
    $res[3] = 2

    5> $set->has(1)
    [Thu Jan  1 13:56:59 2015] I have 1 element(s)
    $res[4] = 1

    6> $set->log_info()
    Can't locate object method "log_info" via package "Example::Construction::Set_v1::__Minions" at reply input line 1.
    7>
