package Mic::Assembler;

use strict;
use Class::Method::Modifiers qw(install_modifier);
use Carp;
use List::MoreUtils qw( any uniq );
use Module::Runtime qw( require_module );
use Params::Validate qw(:all);
use Package::Stash;
use Storable qw( dclone );
use Sub::Name;

use Mic::_Guts;

sub new {
    my ($class, %arg) = @_;

    my $obj = { 
        spec => $arg{-spec} || {},
    };
    bless $obj;
}

sub load_spec_from {
    my ($self, $package) = @_; 

    my $spec = $self->{spec};
    my $cls_stash = Package::Stash->new($package);

    $spec = { %$spec, %{ $cls_stash->get_symbol('%__meta__') || {} } };
    $spec->{name} = $package;
    $self->{cls_stash} = $cls_stash;
    $self->{spec} = $spec;
    return $spec;
}

sub assemble {
    my ($self) = @_;

    my $spec = $self->{spec};
    $self->{cls_stash} ||= Package::Stash->new($spec->{name});

    my $obj_stash;

    my $pkg = $Mic::Bound_implementation_of{ $spec->{name} } || $spec->{implementation};
    $pkg ne $spec->{name}
      or confess "$spec->{name} cannot be its own implementation.";
    my $stash = _get_stash($pkg);

    my $meta = $stash->get_symbol('%__meta__');

    $spec->{implementation} = {
        package => $pkg,
        methods => $stash->get_all_symbols('CODE'),
        has     => {
            %{ $meta->{has} || { } },
        },
        slot_offset => $meta->{slot_offset},
    };
    _collect_non_instance_methods($spec, $meta);
    $obj_stash = Package::Stash->new("$spec->{implementation}{package}::__Assembled");

    _prep_interface($spec);
    _merge_interfaces($spec);

    my $cls_stash = $self->{cls_stash};
    $cls_stash->add_symbol('$__Obj_pkg', $obj_stash->name);
    $cls_stash->add_symbol('%__meta__', $spec) if @_ > 0;

    _add_methods($spec, $obj_stash);
    _make_builder_class($spec);
    _add_class_methods($spec, $cls_stash);
    _check_interface($spec);
    return $spec->{name};
}

sub _collect_non_instance_methods {
    my ($spec, $meta) = @_;

    my $is_classmethod = _interface($meta, 'classmethod');

    foreach my $sub ( keys %{ $spec->{implementation}{methods} } ) {
        my $type;
        if ( $is_classmethod->{$sub} ) {
            $type = 'classmethod';
        }
        if ($type) {
            $spec->{implementation}{$type}{$sub} = delete $spec->{implementation}{methods}{$sub};
        }
    }
}

sub _get_stash {
    my $pkg = shift;

    my $stash = Package::Stash->new($pkg); # allow for inlined pkg

    if ( ! $stash->has_symbol('%__meta__') ) {
        require_module($pkg);
        $stash = Package::Stash->new($pkg);
    }
    if ( ! $stash->has_symbol('%__meta__') ) {
        confess "Package $pkg has no %__meta__";
    }
    return $stash;
}

sub _interface {
    my ($spec, $type) = @_;

    $type ||= 'interface';
    my %must_allow = (
        interface   => [qw( AUTOLOAD can DOES DESTROY )],
        classmethod => [  ],
    );
    if ( $type eq 'interface' && ref $spec->{$type} eq 'HASH') {
        $spec->{interface_meta} = do {
            my @args = %{ $spec->{$type} };
            validate(@args, {
                object     => { type => HASHREF },
                class      => { type => HASHREF },
                extends    => { type => SCALAR | ARRAYREF, optional => 1 },
                invariant  => { type => HASHREF, optional => 1 },
            });
            $spec->{$type};
        };
        $spec->{$type} = [ keys %{ $spec->{$type}{object} } ];
        $Mic::Spec_for{ $spec->{name} }{interface} = $spec->{interface_meta};
    }
    return { map { $_ => 1 } @{ $spec->{$type} }, @{ $must_allow{$type} } };
}

sub _prep_interface {
    my ($spec) = @_;

    return if ref $spec->{interface};
    my $count = 0;
    {

        if (my $methods = $Mic::Spec_for{ $spec->{interface} }{interface}) {
            $spec->{interface_name} = $spec->{interface};
            $spec->{interface} = $methods;
        }
        else {
            $count > 0
              and confess "Invalid interface: $spec->{interface}";
            require_module($spec->{interface});
            $count++;
            redo;
        }
    }
}

sub _merge_interfaces {
    my ($spec, $interfaces, $from_interface) = @_;

    if ( ! $interfaces ) {
        $interfaces = to_aref($spec->{interface}{extends});
    }

    $from_interface ||= {};

    foreach my $super (@{ $interfaces }) {
        $super eq $spec->{name}
          and confess "$spec->{name} cannot extend itself";
        require_module($super);
        my $declared_interface = $Mic::Spec_for{ $super }{interface}
          or confess "Could not find interface '$super'";
        merge($spec->{interface}, $declared_interface, $from_interface);
        $spec->{does}{$super} = 1;
        _merge_interfaces($spec, to_aref($declared_interface->{extends}), $from_interface);
    }
}

sub to_aref {
    my ($x) = @_;

    return [] unless defined $x;
    return ref $x eq 'ARRAY' ? $x : [$x];
}

sub merge {
    my ($h1, $h2, $from) = @_;

    foreach my $k (keys %{ $h2 }) {
        if (exists $h1->{$k}) {
            if (   ref $h1->{$k} eq 'HASH'
                && ref $h2->{$k} eq 'HASH'
            ) {
                merge($h1->{$k}, $h2->{$k}, $from);
            }
        }
        else {
            $h1->{$k} = $h2->{$k};
        }
    }
}

sub _check_interface {
    my ($spec) = @_;
    my $count = 0;
    foreach my $method ( @{ $spec->{interface} } ) {
        defined $spec->{implementation}{methods}{$method}
          or confess "Interface method '$method' is not implemented.";
        ++$count;
    }
    $count > 0 or confess "Cannot have an empty interface.";
}

sub _add_methods {
    my ($spec, $stash) = @_;

    my $in_interface = _interface($spec);

    $spec->{implementation}{methods}{DOES} = sub {
        my ($self, $r) = @_;

        if ( ! $r ) {
            my @items = (( $spec->{interface_name} ? $spec->{interface_name} : () ),
                          $spec->{name}, sort keys %{ $spec->{does} });
            return unless defined wantarray;
            return wantarray ? @items : \@items;
        }

        return    $r eq $spec->{interface_name}
               || $spec->{name} eq $r
               || $spec->{does}{$r}
               || $self->isa($r);
    };
    $spec->{implementation}{methods}{can} = sub {
        my ($self, $f) = @_;

        if ( ! $f ) {
            my @items = sort @{ $spec->{interface} };
            return unless defined wantarray;
            return wantarray ? @items : \@items;
        }
        return UNIVERSAL::can($self, $f);
    };

    while ( my ($name, $meta) = each %{ $spec->{implementation}{has} } ) {

        _validate_slot_def($meta);
        if ( !  $spec->{implementation}{methods}{ $meta->{reader} }
             && $meta->{reader}
             && $in_interface->{ $meta->{reader} } ) {

            $spec->{implementation}{methods}{ $meta->{reader} } = sub { 
                my ($self) = @_;

                return $self->[ $spec->{implementation}{slot_offset}{$name} ];
            };
        }

        if ( !  $spec->{implementation}{methods}{ $meta->{property} }
             && $meta->{property}
             && $in_interface->{ $meta->{property} } ) {

            confess "'property' can only be used from Perl 5.16 onwards"
              if $] lt '5.016';
            $spec->{implementation}{methods}{ $meta->{property} } = sub : lvalue {
                my ($self) = @_;

                return $self->[ $spec->{implementation}{slot_offset}{$name} ];
            };
        }

        if ( !  $spec->{implementation}{methods}{ $meta->{writer} }
             && $meta->{writer}
             && $in_interface->{ $meta->{writer} } ) {

            $spec->{implementation}{methods}{ $meta->{writer} } = sub {
                my ($self, $new_val) = @_;

                $self->[ $spec->{implementation}{slot_offset}{$name} ] = $new_val;
                return $self;
            };
        }
        _add_delegates($spec, $meta, $name);
    }

    while ( my ($name, $sub) = each %{ $spec->{implementation}{methods} } ) {
        next unless $in_interface->{$name};
        $stash->add_symbol("&$name", subname $stash->name."::$name" => $sub); 
    }

    foreach my $name ( @{ $spec->{interface} } ) {
        _add_pre_conditions($spec, $stash, $name, 'object');
        _add_post_conditions($spec, $stash, $name, 'object');
    }
    _add_invariants($spec, $stash);
}

sub _validate_slot_def {
    validate(@_, {
        default  => { type => SCALAR   | CODEREF, optional => 1 },
        handles  => { type => ARRAYREF | HASHREF, optional => 1 },
        init_arg => { type => SCALAR, optional => 1 },
        property => { type => SCALAR, optional => 1 },
        reader   => { type => SCALAR, optional => 1 },
        writer   => { type => SCALAR, optional => 1 },
    });
}

sub _add_invariants {
    my ($spec, $stash) = @_;

    return unless $Mic::Contracts_for{ $spec->{name} }{invariant};
    my $inv_hash =
      (!  ref $spec->{interface}
       &&  $Mic::Spec_for{ $spec->{interface} }{interface_meta}{invariant})

      || $spec->{interface_meta}{invariant}
      or return;

    $spec->{invariant_guard} ||= sub {
        # skip methods called by the invariant
        return if (caller 1)[0] eq $spec->{name};

        foreach my $desc (keys %{ $inv_hash }) {
            my $sub = $inv_hash->{$desc};
            $sub->(@_)
              or confess "Invariant '$desc' violated";
        }
    };
    foreach my $type ( qw[before after] ) {
        install_modifier($stash->name, $type, @{ $spec->{interface} }, $spec->{invariant_guard});
    }
}


sub _add_pre_conditions {
    my ($spec, $stash, $name, $type) = @_;

    return unless $Mic::Contracts_for{ $spec->{name} }{pre};

    _validate_contract_def($spec->{interface_meta}{$type}{$name});
    my $pre_cond_hash = $spec->{interface_meta}{$type}{$name}{require}
      or return;

    my $guard = sub {
        foreach my $desc (keys %{ $pre_cond_hash }) {
            my $sub = $pre_cond_hash->{$desc};
            $sub->(@_)
              or confess "Method '$name' failed precondition '$desc'";
        }
    };
    install_modifier($stash->name, 'before', $name, $guard);
}

sub _add_post_conditions {
    my ($spec, $stash, $name, $type) = @_;

    return unless $Mic::Contracts_for{ $spec->{name} }{post};

    _validate_contract_def($spec->{interface_meta}{$type}{$name});
    my $post_cond_hash = $spec->{interface_meta}{$type}{$name}{ensure}
      or return;

    my $constructor_spec = _constructor_spec($spec);

    my $guard = sub {
        my $orig = shift;
        my $self = shift;

        my @old;
        my @invocant = ($self);
        if ($type eq 'object') {
            @old = ( dclone($self) );
        }
        my $results = [$orig->($self, @_)];
        my $results_to_check = $results;

        if ($type eq 'class' && $name eq $constructor_spec->{name}) {
            $results_to_check = $results->[0];
            @invocant = ();
        }

        foreach my $desc (keys %{ $post_cond_hash }) {
            my $sub = $post_cond_hash->{$desc};
            $sub->(@invocant, @old, $results_to_check, @_)
              or confess "Method '$name' failed postcondition '$desc'";
        }
        return unless defined wantarray;
        return wantarray ? @$results : $results->[0];
    };
    install_modifier($stash->name, 'around', $name, $guard);
}

sub _validate_contract_def {
    validate(@_, {
        ensure   => { type => HASHREF, optional => 1 },
        require  => { type => HASHREF, optional => 1 },
    });
}

sub _make_builder_class {
    my ($spec) = @_;

    my $stash = Package::Stash->new("$spec->{name}::__Util");
    $Mic::Util_class{ $spec->{name} } = $stash->name;

    my $constructor_spec = _constructor_spec($spec);

    my %method = (
        new_object => \&_object_maker,
    );

    $method{main_class} = sub { $spec->{name} };

    $method{build} = sub {
        my (undef, $obj, $arg) = @_;

        my $impl_pkg = $spec->{implementation}{package};
        if ( my $builder = $impl_pkg->can('BUILD') ) {
            $builder->($obj, $arg);
        }
    };

    $method{check_invariants} = sub {
        shift;
        my ($obj) = @_;

        return unless exists $spec->{invariant_guard};
        $spec->{invariant_guard}->($obj);
    };

    my $class_var_stash = Package::Stash->new("$spec->{name}::__ClassVar");

    $method{get_var} = sub {
        my ($class, $name) = @_;
        $class_var_stash->get_symbol($name);
    };

    $method{set_var} = sub {
        my ($class, $name, $val) = @_;
        $class_var_stash->add_symbol($name, $val);
    };

    foreach my $sub ( keys %method ) {
        $stash->add_symbol("&$sub", $method{$sub});
        subname $stash->name."::$sub", $method{$sub};
    }
}

sub _add_class_methods {
    my ($spec, $stash) = @_;

    $spec->{class_methods} = $spec->{implementation}{classmethod};
    _add_default_constructor($spec);

    foreach my $sub ( keys %{ $spec->{class_methods} } ) {
        $stash->add_symbol("&$sub", $spec->{class_methods}{$sub});
        subname "$spec->{name}::$sub", $spec->{class_methods}{$sub};
        _add_pre_conditions($spec, $stash, $sub, 'class');
        _add_post_conditions($spec, $stash, $sub, 'class');
    }
}

sub _add_delegates {
    my ($spec, $meta, $name) = @_;

    if ( $meta->{handles} ) {
        my $method;
        my $target_method = {};
        if ( ref $meta->{handles} eq 'ARRAY' ) {
            $method = { map { $_ => 1 } @{ $meta->{handles} } };
        }
        elsif( ref $meta->{handles} eq 'HASH' ) {
            $method = $meta->{handles};
            $target_method = $method;
        }

        foreach my $meth ( keys %{ $method } ) {
            if ( defined $spec->{implementation}{methods}{$meth} ) {
                confess "Cannot override implemented method '$meth' with a delegated method";
            }
            else {
                my $target = $target_method->{$meth} || $meth;
                $spec->{implementation}{methods}{$meth} = sub { 
                    my $obj = shift;

                    my $delegate = $obj->[ $spec->{implementation}{slot_offset}{ $name } ];
                    if (wantarray) {
                        my @results = $delegate->$target(@_);
                        return @results;
                    }
                    elsif( defined wantarray ) {
                        return $delegate->$target(@_);
                    }
                    else {
                        $delegate->$target(@_);
                        return;
                    }
                }
            }
        }
    }
}

sub _constructor_spec {
    my ($spec) = @_;

    if(! ref $spec->{interface}) {
        my $s;
        $s = $Mic::Spec_for{ $spec->{interface} }{constructor}
          and return $s;
    }
    $spec->{constructor} ||= {};
    return $spec->{constructor};
}

sub _add_default_constructor {
    my ($spec) = @_;

    my $constructor_spec = _constructor_spec($spec);

    $constructor_spec->{name} ||= 'new';
    my $sub_name = $constructor_spec->{name};
    if ( ! exists $spec->{class_methods}{$sub_name} ) {
        $spec->{class_methods}{$sub_name} = sub {
            my $class = shift;
            my ($arg);

            if ( scalar @_ == 1 ) {
                $arg = shift;
            }
            elsif ( scalar @_ > 1 ) {
                $arg = [@_];
            }

            my $builder = Mic::builder_for($class);
            my $obj = $builder->new_object;
            my $kv_args = ref $arg eq 'HASH' ? $arg : {};
            for my $name ( keys %{ $kv_args } ) {

                # handle init_args
                my ($attr, $dup) = grep { $spec->{implementation}{has}{$_}{init_arg} eq $name }
                                        keys %{ $spec->{implementation}{has} };
                if ( $dup ) {
                    confess "Cannot have same init_arg '$name' for attributes '$attr' and '$dup'";
                }
                if ( $attr ) {
                    my $attr_val = $arg->{$name};
                    $obj->[ $spec->{implementation}{slot_offset}{$attr} ] = $attr_val;
                }
            }

            $builder->build($obj, $arg);
            $builder->check_invariants($obj);
            return $obj;
        };
    }
}

sub _object_maker {
    my ($builder, $init) = @_;

    my $class = $builder->main_class;

    my $stash = Package::Stash->new($class);

    my $spec = $stash->get_symbol('%__meta__');
    my $pkg_key = Mic::_Guts::obfu_name('', $spec);
    my $obj = [ ];

    while ( my ($attr, $meta) = each %{ $spec->{implementation}{has} } ) {
        my $init_val = $init->{$attr}
                ? $init->{$attr}
                : (ref $meta->{default} eq 'CODE'
                  ? $meta->{default}->()
                  : $meta->{default});
        my $offset = $spec->{implementation}{slot_offset}{$attr};
        $obj->[$offset] = $init_val;
    }

    bless $obj => ${ $stash->get_symbol('$__Obj_pkg') };
    $Mic::_Guts::Implementation_meta{ref $obj} = $spec->{implementation};

    return $obj;
}

1;

__END__
