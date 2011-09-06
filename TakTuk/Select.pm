###############################################################################
#                                                                             #
#  TakTuk, a middleware for adaptive large scale parallel remote executions   #
#  deployment. Perl implementation, copyright(C) 2006 Guillaume Huard.        #
#                                                                             #
#  This program is free software; you can redistribute it and/or modify       #
#  it under the terms of the GNU General Public License as published by       #
#  the Free Software Foundation; either version 2 of the License, or          #
#  (at your option) any later version.                                        #
#                                                                             #
#  This program is distributed in the hope that it will be useful,            #
#  but WITHOUT ANY WARRANTY; without even the implied warranty of             #
#  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the              #
#  GNU General Public License for more details.                               #
#                                                                             #
#  You should have received a copy of the GNU General Public License          #
#  along with this program; if not, write to the Free Software                #
#  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA #
#                                                                             #
#  Contact: Guillaume.Huard@imag.fr                                           #
#           Laboratoire LIG - ENSIMAG - Antenne de Montbonnot                 #
#           51 avenue Jean Kuntzmann                                          #
#           38330 Montbonnot Saint Martin                                     #
#           FRANCE                                                            #
#                                                                             #
###############################################################################

package TakTuk::Select;

# Creates an empty select object
sub new();
# Adds a descriptor to the set listened by the select
sub add($);
# Removes a descriptor from the select set
# Returns false if the descriptor is not in the set
sub remove($);
# select call
# as in IO::Select, returns an array of three references to arrays
sub select($$$$);
# returns the array of registered handles
sub handles();

###############################################
### TAKTUK                                  ###
### base protocol encoding                  ###
### This is also the exported package for   ###
### external communication (which explains  ###
### the name)                               ###
###############################################

package TakTuk::Select;
use strict; use bytes;

use constant EDESIS=>1;
use constant EDESNF=>2;
use constant EDESNS=>3;

our @select_errors = (
    "Descriptor already in set",
    "Didn't found descriptor to remove",
    "Descriptor not in set");

sub error_msg($) {
    my $error = shift;

    $error--;
    if ($error <= $#select_errors) {
        return $select_errors[$error];
    } else {
        return "Unknown error";
    }
}

sub new () {
    my $class = shift;
    my $data = { vector=>'', handles=>[] };

    bless $data, $class;
    return $data;
}

sub add ($) {
    my $self = shift;
    my $handle = shift;

    if (vec($self->{vector}, fileno($handle), 1) == 0) {
        vec($self->{vector}, fileno($handle), 1) = 1;
        push @{$self->{handles}}, $handle;
        return 0;
    } else {
        return EDESIS;
    }
}

sub remove ($) {
    my $self = shift;
    my $handle = shift;
    my $i=0;
    
    my $handles_list = $self->{handles};
    if (vec($self->{vector}, fileno($handle), 1) == 1) {
        vec($self->{vector}, fileno($handle), 1) = 0;
        while (($i <= $#$handles_list) and ($handles_list->[$i] != $handle)) {
            $i++;
        }
        if ($i <= $#$handles_list) {
            splice @$handles_list, $i, 1;
            return  0;
        } else {
            return EDESNF;
        }
    } else {
        return EDESNS;
    }
}

sub select ($$$$) {
    my $read_select = shift;
    my $write_select = shift;
    my $except_select = shift;
    my $timeout = shift;

    my $rin = defined($read_select)?$read_select->{vector}:undef;
    my $win = defined($write_select)?$write_select->{vector}:undef;
    my $ein = defined($except_select)?$except_select->{vector}:undef;
    my $rout;
    my $wout;
    my $eout;
    my ($nfound, $timeleft) =
        CORE::select($rout=$rin, $wout=$win, $eout=$ein, $timeout);

    if ($nfound == -1) {
        return ();
    } elsif ($nfound == 0) {
        return ([],[],[]);
    } else {
        my $read_set = [];
        my $write_set = [];
        my $except_set = [];
        my $handle;
        
        foreach $handle (@{$read_select->{handles}}) {
            push(@$read_set, $handle) if (vec($rout,fileno($handle),1) == 1);
        }
        foreach $handle (@{$write_select->{handles}}) {
            push(@$write_set, $handle) if (vec($wout,fileno($handle),1) == 1);
        }
        foreach $handle (@{$except_select->{handles}}) {
            push(@$except_set, $handle) if (vec($eout,fileno($handle),1) == 1);
        }
        return ($read_set, $write_set, $except_set);
    }
}

sub handles () {
    my $self=shift;
    return @{$self->{handles}};
}

###############################################
### ARGUMENTS                               ###
###############################################

1;
