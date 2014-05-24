package Convos::Chat;

=head1 NAME

Convos::Chat - Mojolicious controller for IRC chat

=cut

use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON 'j';
use Convos::Core::Commands;
use constant DEFAULT_RESPONSE => "Hey, I don't know how to respond to that. Try /help to see what I can so far.";

=head1 METHODS

=head2 socket

Handle conversation exchange over websocket.

=cut

sub socket {
  my $self  = shift;
  my $login = $self->session('login');

  Mojo::IOLoop->stream($self->tx->connection)->timeout(30);
  Scalar::Util::weaken($self);

  # from browser to backend
  $self->on(
    message => sub {
      my ($self, $octets) = @_;
      my $dom = Mojo::DOM->new($octets)->at('div');
      $self->logf(debug => '[ws] < %s', $octets);

      if ($dom and $dom->{'id'} and $dom->{'data-network'}) {
        @$dom{qw( network target uuid )} = map { delete $dom->{$_} || '' } qw( data-network data-target id );
        $self->_handle_socket_data($dom);
      }
      else {
        $self->_send_400($dom, "Invalid message ($octets)")->finish;
      }
    }
  );

  # from backend to browser
  $self->redis->on(
    message => "convos:user:$login:out" => sub {
      my ($redis, $err, $message, $channel) = @_;

      if ($err) {
        $self->logf(warn => 'Redis subscription fail: %s', $err);
        return $self->finish;
      }

      $message = [$message];

      $self->logf(debug => '[%s] > %s', "convos:user:$login:out", $message);
      $self->format_conversation(
        sub { j(shift @$message) },
        sub {
          my ($self, $messages) = @_;
          $self->send_partial("event/$messages->[0]{event}", target => '', %{$messages->[0]});
        },
      );
    },
  );
}

sub _convos_message {
  my ($self, $args, $input, $response) = @_;
  my $login = $self->session('login');

  $self->send_partial(
    'event/message',
    highlight => 0,
    message   => $input,
    nick      => $login,
    network   => $args->{network},
    status    => 200,
    target    => '',
    timestamp => time,
    uuid      => $args->{uuid} . '_',
  );
  $self->send_partial(
    'event/message',
    highlight => 0,
    message   => $response,
    nick      => $args->{network},
    network   => $args->{network},
    status    => 200,
    target    => '',
    timestamp => time,
    uuid      => $args->{uuid},
  );
}

sub _handle_socket_data {
  my ($self, $dom) = @_;
  my $cmd   = Mojo::Util::html_unescape($dom->text(0));
  my $login = $self->session('login');

  if ($cmd =~ s!^/(\w+)\s*(.*)!!) {
    my ($action, $arg) = ($1, $2);
    $arg =~ s/\s+$//;
    if (my $code = Convos::Core::Commands->can($action)) {
      $cmd = $self->$code($arg, $dom);
    }
    else {
      return $self->_send_400($dom, 'Unknown command. Type /help to see available commands.');
    }
  }
  elsif ($dom->{network} eq 'convos') {
    return $self->_convos_message($dom, $cmd, DEFAULT_RESPONSE);
  }
  elsif ($dom->{target}) {
    $cmd = "PRIVMSG $dom->{target} :$cmd";
  }
  else {
    return;
  }

  if (defined $cmd) {
    my $key = "convos:user:$login:$dom->{network}";
    $cmd = "$dom->{uuid} $cmd";
    $self->logf(debug => '[%s] < %s', $key, $cmd);
    $self->redis->publish($key => $cmd);
    if ($dom->{'data-history'}) {
      $self->redis->rpush("user:$login:cmd_history", $dom->text(0));
      $self->redis->ltrim("user:$login:cmd_history", -30, -1);
    }
  }
}

sub _send_400 {
  my ($self, $args, $message) = @_;

  $self->send_partial(
    'event/server_message',
    status    => 400,
    timestamp => time,
    uuid      => '',
    network   => $args->{'data-network'} || 'any',
    message   => $message,
  );
}

=head1 COPYRIGHT

See L<Convos>.

=head1 AUTHOR

Jan Henning Thorsen

Marcus Ramberg

=cut

1;
