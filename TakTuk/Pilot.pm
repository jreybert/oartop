package TakTuk::Pilot;
use strict; use bytes;
use Carp;

use Exporter;

our $VERSION = "1.0";
our $RELEASE = sprintf "%d", q$Rev: 1 $ =~ /(\d+)/g;
our @ISA = qw(Exporter);

use constant EARGCM => 1;
use constant ETMOUT => 2;
use constant EARGCB => 3;
use constant ETKTRN => 4;
use constant ETKTNR => 5;
use constant ESPIPE => 6;
use constant ESFORK => 7;
use constant ESCLOS => 8;
use constant ESELEC => 9;
use constant ETPBUG => 10;
use constant EARGFH => 11;
use constant EARGTP => 12;

our @messages = (
    "Argument 'command' missing",
    "Timeouted",
    "Argument 'callback' missing",
    "TakTuk is already running",
    "TakTuk is not running",
    "pipe system call failed",
    "fork system call failed",
    "close system call failed",
    "select error",
    "Internal bug in TakTuk Pilot module",
    "Argument 'filehandle' missing",
    "Argument 'type' missing"
);

use TakTuk::Select;
use Data::Dumper;

our @taktuk_streams =
    ('taktuk', 'info', 'status', 'connector', 'default', 'state');

our $has_setsid = eval("use POSIX 'setsid';1")?1:0;
our $read_granularity = 4096;
our $write_granularity = 4096;

# Internal functions
sub dummy_callback(%);
sub no_flush($);
sub taktuk_read_callback(%);
sub taktuk_write_callback(%);
sub set_callback($$$$);

# User interface
sub new();
sub error_msg($);
sub run(%);
sub continue();
sub quiet();
sub verbose();
sub add_callback(%);
sub send_command($);
sub send_termination();
sub add_descriptor(%);
sub remove_descriptor(%);

sub quiet() {
    my $self = shift;

    if ($self->{running} and not $self->{quiet}) {
        return ETKTRN;
    } else {
        $self->{quiet} = 1;
        return 0;
    }
}

sub verbose() {
    my $self = shift;

    if ($self->{running} and $self->{quiet}) {
        return ETKTRN;
    } else {
        $self->{quiet} = 0;
        return 0;
    }
}

sub dummy_callback(%) {
    my %args = @_;

    print STDERR "WARNING: Unhandled TakTuk data on stream $args{stream}\n"
        unless $args{taktuk}->{quiet};
}

sub new() {
    my $self = shift;
    my $data = {};

    $data->{quit} = 0;
    $data->{option} = {};
    $data->{quiet} = 1;
    $data->{setsid} = 0;
    $data->{stream} = {};
    $data->{callback} = {};
    $data->{argument} = {};
    $data->{read} = {callback => {}, argument => {}};
    $data->{write} = {callback => {}, argument => {}};
    $data->{exception} = {callback => {}, argument => {}};
    $data->{running} = 0;
    $data->{read_buffer} = "";
    $data->{write_buffer} = "";
    $data->{read}->{select} = TakTuk::Select->new or die "Select creation\n";
    $data->{write}->{select} = TakTuk::Select->new or die "Select creation\n";
    $data->{exception}->{select} =
        TakTuk::Select->new or die "Select creation\n";

    return bless $data, $self;
}

sub error_msg($) {
    my $number = shift;

    if (($number < 1) or ($number > scalar(@messages))) {
        return "Unknown error";
    } else {
        return $messages[$number-1];
    }
}

sub run(%) {
    my $self = shift;
    my %arguments = @_;
    $self->{command} = $arguments{command};
    $self->{timeout} = $arguments{timeout};
    
    return EARGCM unless defined($self->{command});
    return ETKTRN if $self->{running};

    my ($command, $remaining) = split / /,$self->{command},2; 

    foreach my $stream (@taktuk_streams) {
        if (not exists($self->{option}->{$stream})) {
            if ($self->{quiet}) {
                $self->{option}->{$stream} = "-o $stream";
            } else {
                $self->add_callback(callback=>\&dummy_callback,
                                    stream=>$stream);
            }
        }
    }
    foreach my $stream (keys(%{$self->{option}})) {
        $command .= " ".$self->{option}->{$stream};
    }

    my ($taktuk_read, $taktuk_write);
    pipe($self->{read_channel}, $taktuk_write) or return ESPIPE;
    pipe($taktuk_read, $self->{write_channel}) or return ESPIPE;

    $self->{pid} = fork();
    return ESFORK unless defined($self->{pid});
    if ($self->{pid}) {
        close($taktuk_read) or return ESCLOS;
        close($taktuk_write) or return ESCLOS;
        binmode($self->{read_channel});
        no_flush($self->{write_channel});
    } else {
        setsid() if $self->{setsid} and $has_setsid;
        close($self->{read_channel}) or die "$!";
        close($self->{write_channel}) or die "$!";
        open(STDIN,"<&",$taktuk_read) or die "$!";
        open(STDOUT,">&",$taktuk_write) or die "$!";
        no_flush(\*STDOUT);
        close($taktuk_read) or die "$!";
        close($taktuk_write) or die "$!";
        exec("$command $remaining") or die "$!";
    }

    $self->add_descriptor(type=>'read', filehandle=>$self->{read_channel},
                          callback=>\&taktuk_read_callback);
    if (length($self->{write_buffer})) {
        $self->add_descriptor(type=>'write', filehandle=>$self->{write_channel},
                              callback=>\&taktuk_write_callback);
    } else {
        if ($self->{quit}) {
            close($self->{write_channel});
            delete $self->{write_channel};
        }
    }

    $self->{running} = 1;
    my $result = $self->continue();
    return $result if $result;
    $self->{running} = 0;

    $self->{write_buffer} = "";
    $self->{read_buffer} = "";
    close($self->{read_channel}) or return ESCLOS;
    if (exists($self->{write_channel})) {
        close($self->{write_channel}) or return ESCLOS;
    }
    return 0;
}

sub continue() {
    my $self = shift;

    return ETKTNR unless $self->{running};
    
    # Main processing loop
    while (scalar($self->{read}->{select}->handles())) {
        my @select_result = TakTuk::Select::select($self->{read}->{select},
                        $self->{write}->{select}, $self->{exception}->{select},
                        $self->{timeout});
        if (scalar(@select_result)) {
            my @types = ('read', 'write', 'exception');
            my $rank = 0;
            $rank++ while $rank < 3 and not scalar(@{$select_result[$rank]});
            return ETMOUT if $rank == 3;
            while ($rank < 3) {
                my $type = $types[$rank];
                my $handle = shift @{$select_result[$rank]};
                my $callback = $self->{$type}->{callback}->{$handle};
                my $argument = $self->{$type}->{argument}->{$handle};

                return ETPBUG unless defined $callback;
                my %call_args = (taktuk=>$self,
                                 type=>$type,
                                 filehandle=>$handle,
                                 argument=>$argument);
                &$callback(%call_args);
                $rank++
                    while $rank < 3 and not scalar(@{$select_result[$rank]});
            }
        } else {
            return ESELEC;
        }
        if (exists($self->{write_channel}) and $self->{quit}
                and not length($self->{write_buffer})) {
            close($self->{write_channel}) or return ESCLOS;
            delete($self->{write_channel});
        }
    }
    return 0;
}

sub no_flush($) {
    my $new_fd = shift;
    my $old_fd=select($new_fd);
    $|=1;
    select($old_fd);
}

sub taktuk_read_callback(%) {
    my %args = @_;
    my $self = $args{taktuk};
    my $descriptor = $args{filehandle};
    my $done = 0;

    my $result = sysread($descriptor, $self->{read_buffer}, $read_granularity,
                                                length($self->{read_buffer}));
    carp "$!" unless defined $result;
    if (not $result) {
        $self->remove_descriptor(type=>'read', filehandle=>$descriptor);
        $done = 1;
    }

    while (not $done) {
        if (length($self->{read_buffer}) >= 4) {
            my ($size) = unpack("N", $self->{read_buffer});
            if (length($self->{read_buffer}) >= $size + 4) {
                my $buffer = substr $self->{read_buffer}, 4, $size;
                my ($stream, $data) = split / /, $buffer, 2;
                $self->{read_buffer} = substr $self->{read_buffer}, $size + 4;

                my $result = {};
                foreach my $field (@{$self->{stream}->{$stream}}) {
                    my $field_size = unpack("N", $data);
                    $result->{$field} = substr($data, 4, $field_size);
                    $data = substr $data, $field_size+4;
                }
                my %call_args = (taktuk=>$self,
                                 argument=>$self->{argument}->{$stream},
                                 stream=>$stream,
                                 fields=>$result);

                if (exists($self->{callback}->{$stream})) {
                    &{$self->{callback}->{$stream}}(%call_args);
                } elsif (exists($self->{callback}->{default})) {
                    &{$self->{callback}->{default}}(%call_args);
                } else {
                    carp "Internal bug in TakTuk::Pilot\n";
                }
            } else {
                $done = 1;
            }
        } else {
            $done = 1;
        }
    }
}

sub taktuk_write_callback(%) {
    my %args = @_;
    my $self = $args{taktuk};
    my $descriptor = $args{filehandle};
    my $size = length($self->{write_buffer});
    my $write_size = ($size > $write_granularity) ? $write_granularity : $size;

    my $result = syswrite($descriptor, $self->{write_buffer}, $write_size);
    carp "$!" unless defined($result);

    if ($result < $size) {
        $self->{write_buffer} = substr $self->{write_buffer}, $result;
    } else {
        $self->{write_buffer} = "";
        $self->remove_descriptor(type=>'write', filehandle=>$descriptor);
    }
}

sub set_callback($$$$) {
    my $self = shift;
    my $callback = shift;
    my $argument = shift;
    my $stream = shift;
    my $fields = shift;

    my $option = '-o '.$stream.'=\'$user_scalar="'.$stream.' "';
    foreach my $field (@$fields) {
        $option .= '.pack("N",length($'.$field.')).$'.$field;
    }
    $option .= ',pack("N",length($user_scalar)).$user_scalar\'';

    $self->{option}->{$stream} = $option;
    $self->{stream}->{$stream} = $fields;
    $self->{callback}->{$stream} = $callback;
    $self->{argument}->{$stream} = $argument;
}

sub add_callback(%) {
    my $self = shift;
    my %arguments = @_;
    my $callback = $arguments{callback};
    my $argument = $arguments{argument};
    my $stream = $arguments{stream};
    my $fields = $arguments{fields};

    return EARGCB unless defined($callback);
    $stream = 'default' unless defined($stream);
    $fields = [] unless defined($fields);

    if ($stream eq 'default') {
        foreach my $taktuk_stream (@taktuk_streams) {
            $self->set_callback($callback, $argument, $taktuk_stream, $fields)
                unless exists($self->{option}->{$taktuk_stream});
        }
    } else {
        $self->set_callback($callback, $argument, $stream, $fields);
    }
    return 0;
}

sub send_command($) {
    my $self = shift;
    my $command = shift;

    if (length($command)) {
        if (not length($self->{write_buffer}) and $self->{running}) {
            $self->add_descriptor(type=>'write',
                                  filehandle=>$self->{write_channel},
                                  callback=>\&taktuk_write_callback);
        }
        $self->{write_buffer} .= "$command\n";
    }
}

sub send_termination() {
    my $self = shift;

    $self->{quit} = 1;
}

sub add_descriptor(%) {
    my $self = shift;
    my %arguments = @_;
    my $type = $arguments{type};
    my $descriptor = $arguments{filehandle};
    my $callback = $arguments{callback};
    my $argument = $arguments{argument};

    return EARGCB unless defined $callback;
    return EARGFH unless defined $descriptor;
    return EARGTP unless defined $type;

    $self->{$type}->{callback}->{$descriptor} = $callback;
    $self->{$type}->{argument}->{$descriptor} = $argument;
    my $error = $self->{$type}->{select}->add($descriptor);
    return ESELEC if $error;
    return 0;
}

sub remove_descriptor(%) {
    my $self = shift;
    my %arguments = @_;
    my $type = $arguments{type};
    my $descriptor = $arguments{filehandle};

    return EARGFH unless defined $descriptor;
    return EARGTP unless defined $type;

    delete($self->{$type}->{callback}->{$descriptor});
    delete($self->{$type}->{argument}->{$descriptor});
    my $error = $self->{$type}->{select}->remove($descriptor);
    return ESELEC if $error;
    return 0;
}

1;
__END__

=pod TakTuk pilot Perl module

=begin html

<center><h1>USER MANUAL</h1></center>

=end html

=head1 NAME

TakTuk::Pilot - Perl module that ease C<taktuk(1)> execution and related I/O
management

=head1 SYNOPSIS

  use TakTuk::Pilot;
  
  our @line_counter;
  
  sub output_callback(%) {
      my %parameters = @_;
      my $field = $parameters{fields};
      my $rank = $field->{rank};
      my $argument = $parameters{argument};
  
      $argument->[$rank] = 1 unless defined($argument->[$rank]);
      print "$field->{host}-$rank : ".
            "$argument->[$rank] > $field->{line}\n";
      $argument->[$rank]++;
  }
  
  sub user_input_callback(%) {
      my %parameters = @_;
      my $taktuk = $parameters{taktuk};
      my $descriptor = $parameters{filehandle};
      my $buffer;
  
      my $result = sysread($descriptor, $buffer, 1024);
      warn "Read error $!" if not defined($result);
      # basic parsing, we assume input is buffered on a line basis
      chomp($buffer);
  
      if (length($buffer)) {
          print "Executing $buffer\n";
          $taktuk->send_command("broadcast exec [ $buffer ]");
      }
      if (not $result) {
          print "Terminating\n";
          $taktuk->remove_descriptor(type=>'read',
                                     filehandle=>$descriptor);
          $taktuk->send_termination();
      }
  }
  
  die "This script requieres as arguments hostnames to contact\n"
      unless scalar(@ARGV);
  
  my $taktuk = TakTuk::Pilot->new();
  $taktuk->add_callback(callback=>\&output_callback, stream=>'output',
                        argument=>\@line_counter,
                        fields=>['host', 'rank', 'line']);
  $taktuk->add_descriptor(type=>'read', filehandle=>\*STDIN,
                          callback=>\&user_input_callback);
  $taktuk->run(command=>"taktuk -s -m ".join(" -m ", @ARGV));

=head1 DESCRIPTION

The TakTuk::Pilot Perl module ease the use of B<TakTuk> from within a Perl
program (see C<taktuk(1)> for a detailed description of B<TakTuk>). It
transparently manages I/O exchanges as well as B<TakTuk> data demultiplexing
and decoding.

=head1 CONSTRUCTOR

=over

=item B<new>B<()>

Creates a new B<TakTuk> object on which the following method can be called.

=back

=head1 METHODS

=over

=item B<add_callback(%)>

Adds a callback function associated to some B<TakTuk> output stream to the
calling B<TakTuk> object. This callback function will be called by
B<TakTuk::Pilot> for each batch of output data incoming from the related
stream. The hash passed as argument to this function call may contain the
following fields:

  callback => reference to the callback fonction (mandatory)
  stream   => stream related to this callback, might be
              'default' (mandatory)
  fields   => reference to an array of fields names relevant
              to the user
  argument => scalar that should be passed to each callback
              function call

The callback function should accept a hash as argument. This hash will be
populated with the following fields :

  taktuk   => reference to the taktuk object calling this
              callback
  argument => scalar given at callback addition or undef
  stream   => stream on which output data came
  fields   => reference to a hash containing a
              fieldname/value pair for each field requested
              upon callback addition

=item B<send_command($)>

Sends to the calling B<TakTuk> object the command passed as argument. Note that
if the B<TakTuk> object is not running, this command will be buffered and
executed upon run.

=item B<send_termination>B<()>

Sends to the calling B<TakTuk> object a termination command. As for
C<send_command>, if the B<TakTuk> object is not running, this command will be
issued upon run.

=item B<run(%)>

Runs B<TakTuk>, executing pending commands and waiting for B<TakTuk> output.
Note that this function is blocking: it waits for B<TakTuk> outputs, possibly
calls related callback functions and returns when B<TakTuk> terminates. Thus,
all B<TakTuk> commands should be given either before calling C<run> or within a
callback function.

This commands takes a hash as argument that may contain the following fields:

  command => TakTuk command line to be executed
  timeout => optional timeout on the wait for TakTuk output

Upon occurence of the timeout (if one has been given), C<run> will returns an
C<ETMOUT> error code. Note the in this case B<TakTuk> execution will not be
terminated and should be resumed at some point by calling C<continue>.

=item B<continue>B<()>

Resumes a B<TakTuk> execution interrupted by timeout occurence.

=item B<add_descriptor(%)>

Because the call to C<run> is blocking, waiting for B<TakTuk> output, it might
be interesting to let the C<TakTuk::Pilot> module monitor I/O occurence related
to other file descriptors.
This is the intent of C<add_descriptor>. This function takes a hash as
parameter in which the following fields might be defined:

  type       => 'read', 'write' or 'exception', this is the
                type of I/O possiblities that should be
                monitored on the descriptor, as in select
                system call (mandatory).
  filehandle => file descriptor to monitor (mandatory).
  callback   => reference to the callback function that
                should be called when I/O is possible on the
                file descriptor.
  argument   => optional scalar value that will be passed
                with each call to the callback function

The callback function should also accept a hash as an argument in which the
following fields will be defined:

  taktuk     => reference to the TakTuk object from which
                the function was called.
  type       => type of I/O occuring (as in add_callback)
  filehandle => the related file descriptor. Notice that the
                user is in charge of performing the I/O
                operation itslef (sysread or syswrite).
                Notice also that, because of the use of a
                select in TakTuk::Pilot, the use of buffered
                I/O on this descriptor is strongly discouraged
  argument   => the argument that was given to add_descriptor

=item B<remove_descriptor(%)>

Function that should be called to remove from the B<TakTuk> object a descriptor
previously added with C<add_descriptor>. It takes a hash as argument in which
the following fields may be defined:

  type       => type of I/O (see add_descriptor)
  filehandle => file descriptor to remove

=item B<quiet>B<() / verbose>B<()>

Change verbosity of C<TakTuk::Pilot> on STDOUT (default is quiet). Should not
be called when B<TakTuk> is running.

=item B<error_msg($)>

Static function. Returns a character string that corresponds to the error code
given as argument. The error code should be one of the values returned by other
C<TakTuk::Pilot> functions (C<add_callback>, C<send_command>,
C<send_termination>, ...).

=back

=head1 ERRORS

When an error occur in one of these functions, it returns a non nul numeric
error code. This code can take one of the following values:

=over

=item B<TakTuk::Pilot::EARGCM>

Field 'command' is missing in a call to C<run>.

=item B<TakTuk::Pilot::EARGCB>

Field 'callback' is missing in a call to C<add_callback> or C<add_descriptor>.

=item B<TakTuk::Pilot::EARGFH>

Field 'filehandle' is missing in a call to C<add_descriptor> or
C<remove_descriptor>.

=item B<TakTuk::Pilot::EARGTP>

Field 'type' is missing in a call to C<add_descriptor> or
C<remove_descriptor>.

=item B<TakTuk::Pilot::ETMOUT>

A timeout occured in a call to C<run>.

=item B<TakTuk::Pilot::ETKTRN>

B<TakTuk> is alredy running but C<run>, C<verbose> or C<quiet> has been called.

=item B<TakTuk::Pilot::ETKTNR>

B<TakTuk> is not running but C<continue> has been called.

=item B<TakTuk::Pilot::ESPIPE>

A call to C<pipe> failed in C<TakTuk::Pilot> (the error should be in $!).

=item B<TakTuk::Pilot::ESFORK>

A call to C<fork> failed in C<TakTuk::Pilot> (the error should be in $!).

=item B<TakTuk::Pilot::ESCLOS>

A call to C<close> failed in C<TakTuk::Pilot> (the error should be in $!).

=item B<TakTuk::Pilot::ESELEC>

A call to C<select> failed in C<TakTuk::Pilot> (the error should be in $!).

=item B<TakTuk::Pilot::ETPBUG>

Internal bug detected in C<TakTuk::Pilot>.

=back

=head1 SEE ALSO

C<tatkuk(1)>, C<taktukcomm(3)>, C<TakTuk(3)>

=head1 AUTHOR

The original concept of B<TakTuk> has been proposed by Cyrille Martin in his
PhD thesis. People involved in this work include Jacques Briat, Olivier
Richard, Thierry Gautier and Guillaume Huard.

The author of the version 3 (perl version) and current maintainer of the
package is Guillaume Huard.

=head1 COPYRIGHT

The C<TakTuk> communication interface library is provided under the terms
of the GNU General Public License version 2 or later.

=cut
