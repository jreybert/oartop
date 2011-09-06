#!/usr/bin/perl -w

use strict;

use Sys::Hostname;
my $host = hostname;

my (@lines, @new_line, @old_line, $new_ticks, $old_ticks, $diff_ticks);
my ($total, $free, $buffer, $cached);
my @interfaces = ("eth0", "ib0");
my $nb_int = @interfaces;
my @int_up_old = ( (0) x $nb_int);
my @int_down_old = ( (0) x $nb_int);

$old_ticks = 0;
@old_line = ( (0) x 5);

open(STAT, '<', '/proc/stat') or die $!; 
open(MEM, '<', '/proc/meminfo') or die $!;
open(NET, '<', '/proc/net/dev') or die $!;

my $home = $ENV{ HOME };
my $root = "$home/.oartop";
my $top_trace = 1;
my $mem_trace = 0;
my $net_trace = 0;

open (UP, '<', "$root/up") or die $!;

my $freq = <UP>;
while ( $freq != 0 ) {

  my $top_str="";
  if ($top_trace) {
    @lines = <STAT>;
    @new_line = split (/ +/, (grep(/^cpu /, @lines))[0]);
    my $usage_user = ($new_line[1] - $old_line[1]) + ($new_line[2] - $old_line[2]);
    my $usage_system = ($new_line[3] - $old_line[3]);
    my $total = $usage_user + $usage_system + ($new_line[4] - $old_line[4]);
    my $user = ((100*$usage_user)/$total);
    my $system = ((100*$usage_system)/$total);
    $top_str="$user:$system\n";
  }

  my $mem_str="";
  if ($mem_trace) {
    ($total, $free, $buffer, $cached) = <MEM>;
    chomp($total, $free, $buffer, $cached);
    $total =~ s/[^0-9]//g;
    $free =~ s/[^0-9]//g;
    $buffer =~ s/[^0-9]//g;
    $cached =~ s/[^0-9]//g;
    $mem_str="$total:$free:$buffer:$cached\n";
  }

  my $net_str="";
  if ($net_trace) {
    my @net_file= <NET>;
    my $i=0;
    foreach my $int (@interfaces) {
      my @tmp_line = split (/:|\s+/, (grep(/^\s+$int/, @net_file))[0]);
      my $down = $tmp_line[2] - $int_down_old[$i];
      my $up = $tmp_line[10] - $int_up_old[$i];
      $int_down_old[$i] = $tmp_line[2];
      $int_up_old[$i] = $tmp_line[10];
      $net_str+="$int $down $up\n";
      $i++;
    }
  }

  open TOP, '>', "$root/$host";
  print TOP $top_str.$mem_str.$net_str;
  close TOP;

  sleep $freq;
  @old_line = @new_line;
  if ($top_trace) {
    seek(STAT, 0, 0);
  }
  if ($mem_trace){
    seek(MEM, 0, 0);
  }
  if ($net_trace) {
    seek(NET, 0, 0); 
  }
  seek(UP, 0, 0);
  ($freq, $mem_trace, $net_trace) = split(/:/, <UP>);
}
close STAT;
close MEM;
close NET;
close UP;
