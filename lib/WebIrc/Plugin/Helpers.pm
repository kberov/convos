package WebIrc::Plugin::Helpers;

=head1 NAME

WebIrc::Plugin::Helpers - Mojo's little helpers

=cut

use Mojo::Base 'Mojolicious::Plugin';
use WebIrc::Core::Util ();
use Mojo::JSON;

my $JSON = Mojo::JSON->new;

=head1 HELPERS

=head2 form_block

  %= form_block $name, class => [$str, ...] begin
  ...
  % end

The code above will create this markup:

  <div class="@$class" title="$error">
    ...
  </div>

In addition, <@$class> will contain "error" if C<$error> can be fetched from the
stash hash C<errors>, using C<$name> as key.

=cut

sub form_block {
  my $content = pop;
  my ($c, $field, %args) = @_;
  my $error = $c->stash('errors')->{$field} // '';
  my $classes = $args{class} ||= [];

  push @$classes, 'error' if $error;

  $c->tag(div => class => join(' ', @$classes), title => $error, $content);
}

=head2 parse_command $data

Takes a websocket command, parses it into a IRC resposne

=cut

my %commands = (
  j     => 'JOIN',
  join   => 'JOIN',
  t     => sub { my $data = pop; "TOPIC $data->{target}" . ($data->{cmd} ? ' :' . $data->{cmd} : '') },
  topic => sub { my $data = pop; "TOPIC $data->{target}" . ($data->{cmd} ? ' :' . $data->{cmd} : '') },
  w     => 'WHOIS',
  whois => 'WHOIS',
  nick  => 'NICK',
  me   => sub { my $data = pop; "PRIVMSG $data->{target} :\x{1}ACTION $data->{cmd}\x{1}" },
  msg  => sub { my $data = pop; $data->{cmd} =~ s!^(\w+)\s*!!;  "PRIVMSG $1 :$data->{cmd}" },
  part => sub { my $data = pop; "PART " . ($data->{cmd} || $data->{target}) },
  close=> sub { my ($self,$data) = @_;
                my $target=$data->{cmd} || $data->{target};
                $self->redis->sismember("connection:@{[$data->{cid}]}:conversations",$target, sub {
                  my ($redis,$member)=@_;
                  return unless $member;
                  $self->redis->srem("connection:@{[$data->{cid}]}:conversations",$target);
                  $self->send_json({cid => $data->{cid},status=>200, closed=>1,target=>$target});
                });
                return;
  },
  reconnect=> sub { my ($self,$data) = @_;
                $self->redis->publish('core:control',"restart:".$data->{cid});
                return;
  },
  
  help => sub {
    my ($self, $data) = @_;
    $self->send_json(
      {cid => $data->{cid}, status => 200, message => "Available Commands:\nj\tw\tme\tmsg\tpart\tnick\thelp"});
    return;
  }
);

sub parse_command {
  my ($self, $data) = @_;
  if ($data->{cmd}) {
    if ($data->{cmd} =~ s!^/(\w+)\s*!!) {
      my ($cmd) = $1;
      if (my $irc_cmd = $commands{$cmd}) {
        return $irc_cmd->($self, $data) if (ref $irc_cmd);
        return $irc_cmd . ' ' . $data->{cmd};
      }
      else {
        $self->send_json({cid => $data->{cid}, status => '401', message => 'Unknown command'});
      }
    }
    else {
      return "PRIVMSG $data->{target} :$data->{cmd}";
    }
  }
  return;
}

=head2 logf

See L<WebIrc::Core::Util/logf>.

=head2 redis

Returns a L<Mojo::Redis> object.

=head3 as_id

strip non-word characters from input.


=head1 METHODS

=head2 register

Will register the L</HELPERS> above.

=cut

sub register {
  my ($self, $app) = @_;

  $app->helper(form_block    => \&form_block);
  $app->helper(parse_command => \&parse_command);
  $app->helper(logf          => \&WebIrc::Core::Util::logf);
  $app->helper(format_time => sub { my $self = shift; WebIrc::Core::Util::format_time(@_); });
  $app->helper(redis => sub { shift->app->redis(@_) });
  $app->helper(as_id => sub { my ($self, $val) = @_; $val =~ s/\W+//g; $val });
  $app->helper(
    send_json => sub {
      my $self = shift;
      $self->send({text => $JSON->encode(shift)});
      $self->log->debug('JSON Error:' . $JSON->error) if $JSON->error;
    }
  );
  $app->helper(
    is_active => sub {
      my ($self, $c, $target) = @_;
      if ($c->{id} == $self->param('cid')) {
        return 1 if !defined $target && !defined $self->param('target');
        return 1 if defined $target && defined $self->param('target') && $target eq $self->param('target');
      }
      return 0;
    }
  );
}

=head1 AUTHOR

Jan Henning Thorsen - C<jhthorsen@cpan.org>

=cut

1;
