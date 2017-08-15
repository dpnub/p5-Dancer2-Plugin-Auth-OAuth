package Dancer2::Plugin::Auth::OAuth::Provider;

use strict;
use warnings;

use DateTime;
use Digest::MD5 qw(md5_hex);
use HTTP::Request::Common;
use JSON::MaybeXS;
use LWP::UserAgent;
use Net::OAuth;
use Scalar::Util qw( blessed );
use URI::Query;

sub new {
    my ($class, $settings) = @_;
    my $self = bless {
        settings => $settings,
    }, $class;

    for my $default (keys %{$self->config}) {
        $self->{settings}{providers}{$self->_provider}{$default} ||= $self->config->{$default};
    }

    my $protocol_version = $self->provider_settings->{version} || 2;
    $self->{protocol_version} = $protocol_version;

    $self->{ua} ||= LWP::UserAgent->new();
    $self->{ua}->env_proxy; # c'mon make this default behaviour already!

    return $self;
}

sub post_process {
    # Provider:: module should override this if needed/wanted
    my $self = shift;

    return 1;
}

sub _provider {
    return (split '::', blessed($_[0]))[-1];
}

sub _stringify_json_booleans {
    my ($self, $obj) = @_;

    while( my ($k, $v) = each %{$obj} ) {
        $obj->{$k} = $self->_stringify_json_booleans( $v )
            if( ref($v) && ref($v) eq 'HASH' );
        $obj->{$k} = "$v"
            if( blessed( $v ) );
    }

    return $obj;
}

sub _default_args_v1 {
    my $self = shift;

    return (
        consumer_key     => $self->provider_settings->{tokens}{consumer_key},
        consumer_secret  => $self->provider_settings->{tokens}{consumer_secret},
        signature_method => $self->provider_settings->{signature_method} || 'HMAC-SHA1',
        timestamp        => DateTime->now->epoch,
        nonce            => md5_hex(time),
    );
}

sub _callback_url {
    my $self = shift;

    # construct the callback url
    return sprintf "%s%s/%s/callback",
        $self->settings->{base},
        $self->settings->{prefix},
        lc($self->_provider)
    ;
}


sub ua {
    return $_[0]->{ua};
}

sub protocol_version {
    return $_[0]->{protocol_version};
}

sub settings {
    return $_[0]->{settings};
}

sub provider_settings {
    my $self = shift;
    return $self->{settings}{providers}{$self->_provider};
}

sub authentication_url {
    my ( $self, $base ) = @_;

    $self->settings->{base} ||= $base;

    if( $self->protocol_version < 2 ) {
        # oAuth 1.0 / 1.0a
        $Net::OAuth::PROTOCOL_VERSION = $self->protocol_version;
        my $request = Net::OAuth->request("request token")->new(
            $self->_default_args_v1,
            request_method   => 'POST',
            request_url      => $self->provider_settings->{urls}{request_token_url},
            callback         => $self->_callback_url,
        );
        $request->sign;

        my $res = $self->ua->request(POST $request->to_url);
        if ($res->is_success) {
            my $response = Net::OAuth->response('request token')->from_post_body($res->content);
            my $uri = URI->new( $self->provider_settings->{urls}{authorize_url} );
               $uri->query_form( oauth_callback => $self->_callback_url, oauth_token => $response->token );

            return $uri->as_string;
        } else {
            return $self->settings->{error_url} || '/';
        }
    } else {
        # oAuth 2 and up
        my $uri = URI->new( $self->provider_settings->{urls}{authorize_url} );
        my %query = (
          client_id     => $self->provider_settings->{tokens}{client_id},
          redirect_uri  => $self->_callback_url,
          %{ $self->provider_settings->{query_params}{authorize} || {} },
        );
        $uri->query_form( %query );
        return $uri->as_string;
    }
}

sub callback {
    my ($self, $request, $session) = @_;

    # this code may be called before authentication_url()
    # (multiple processes), so we must make sure the base
    # setting isn't undef
    $self->settings->{base} ||= $request->uri_base;

    my $provider = lc $self->_provider;
    my $session_data = $session->read('oauth') || {};

    if( $self->protocol_version < 2 ) {
        my $at_request = Net::OAuth->request( 'access token' )->new(
           $self->_default_args_v1,
            token          => $request->param('oauth_token'),
            token_secret   => '',
            verifier       => $request->param('oauth_verifier'),

            request_url    => $self->provider_settings->{urls}{access_token_url},
            request_method => 'POST'
        );
        $at_request->sign;

        my $ua_response = $self->ua->request(
            POST $at_request->to_url, [
                'oauth_verifier', $request->param('oauth_verifier')
            ]
        );

        if( $ua_response->is_success ) {
            my $response = Net::OAuth->response( 'access token' )->from_post_body( $ua_response->content );
            $session_data->{$provider} = {
                access_token         => $response->token,
                access_token_secret  => $response->token_secret,
                extra                => $response->extra_params,
            };
        }
    } else {
        my $uri  = URI->new( $self->provider_settings->{urls}{access_token_url} );
        my %args = (
                client_id     => $self->provider_settings->{tokens}{client_id},
                client_secret => $self->provider_settings->{tokens}{client_secret},
                code          => $request->param('code'),
                grant_type    => 'authorization_code',
                redirect_uri  => $self->_callback_url,
       );
        my $response = $self->{ua}->request( POST $uri->as_string, \%args );

        if( $response->is_success ) {
            my $content_type = $response->header('Content-Type');
            my $params = {};
            if( $content_type =~ m/json/ || $content_type =~ m/javascript/ ) {
                $params = decode_json( $response->content );
            } else {
                $params = URI::Query->new( $response->content )->hash;
            }

            for my $key (qw/access_token expires expires_in id_token token_type id issued_at scope instance_url refresh_token signature/) {
                $session_data->{$provider}{$key} = $params->{$key}
                    if $params->{$key};
            }
        }
    }
    $session->write('oauth', $session_data);

    # fetch user info or whatever we want to do at this point
    $self->post_process( $session );
}

1;
