use strict;
use warnings;

package CATS::CurrentUser;

sub new { bless $_[1], $_[0] }
sub id { $_[0]->{id} }
sub is_root { $_[0]->{privs}->{is_root} }
sub privs { $_[0]->{privs} }

1;

package CATS::Init;

use Data::Dumper;
use Storable qw();

use CATS::Contest;
use CATS::DB;
use CATS::Globals qw($contest $t $sid $cid $uid $is_root $is_jury $user);
use CATS::IP;
use CATS::Messages qw(msg);
use CATS::Output qw(init_template);
use CATS::Privileges;
use CATS::Redirect;
use CATS::Settings qw($settings);
use CATS::Utils;

# Authorize user, initialize permissions and settings.
sub init_user {
    my ($p) = @_;
    $sid = $p->web_param('sid') || '';
    $is_root = 0;
    $uid = undef;
    $user = CATS::CurrentUser->new({ privs => {}, id => undef });
    my $bad_sid = length $sid > 30;
    my $enc_settings;
    my $current_ip = CATS::IP::get_ip;
    if ($sid ne '' && !$bad_sid) {
        (
            $uid, $user->{name}, my $srole, my $last_ip, my $multi_ip, my $locked,
            $user->{git_author_name}, $user->{git_author_email}, $enc_settings
        ) =
            $dbh->selectrow_array(q~
                SELECT id, team_name, srole, last_ip, multi_ip, locked,
                git_author_name, git_author_email, settings
                FROM accounts WHERE sid = ?~, undef,
                $sid);
        my $bad_ip = !$multi_ip && ($last_ip || '') ne $current_ip;
        $bad_sid = !defined($uid) || $bad_ip || $locked;
        if (!$bad_sid) {
            $user->{privs} = CATS::Privileges::unpack_privs($srole);
            $is_root = $user->is_root;
            $user->{id} = $uid;
        }
    }

    CATS::Settings::init($enc_settings, $p->{lang}, $p->get_cookie('settings'));

    if ($bad_sid) {
        return $p->forbidden if $p->web_param('noredir');
        init_template($p, $p->{json} || $p->{f} =~ /^api_/ ? 'bad_sid.json.tt' : 'login.html.tt');
        $sid = '';
        my $redir = CATS::Redirect::pack_params($p);
        $t->param(href_login => CATS::Utils::url_function('login', redir => $redir));
        msg(1002);
    }
}

sub extract_cid_from_cpid {
    my ($p) = @_;
    $p->{cpid} or return;
    return $dbh->selectrow_array(q~
        SELECT contest_id FROM contest_problems WHERE id = ?~, undef,
        $p->{cpid});
}

sub init_contest {
    my ($p) = @_;
    $cid = $p->{cid} || $p->{clist}->[0] || extract_cid_from_cpid($p) || $settings->{contest_id} || '';
    if ($contest && ref $contest ne 'CATS::Contest') {
        warn "Strange contest: $contest from ", $ENV{HTTP_REFERER} || '';
        warn Dumper($contest);
        undef $contest;
    }
    $contest ||= CATS::Contest->new;
    $contest->load($cid);
    $settings->{contest_id} = $cid = $contest->{id};

    $user->{diff_time} = $user->{ext_time} = 0;
    $is_jury = $user->{is_virtual} = $user->{is_participant} = $user->{is_remote} = $user->{is_ooc} = 0;
    # Authorize user in the contest.
    if (defined $uid) {
        (
            $user->{ca_id}, $user->{is_participant}, $is_jury, $user->{site_id}, $user->{is_site_org},
            $user->{is_virtual}, $user->{is_remote}, $user->{is_ooc},
            $user->{personal_diff_time}, $user->{diff_time},
            $user->{personal_ext_time}, $user->{ext_time},
            $user->{site_name}
        ) = $dbh->selectrow_array(q~
            SELECT
                CA.id, 1, CA.is_jury, CA.site_id, CA.is_site_org,
                CA.is_virtual, CA.is_remote, CA.is_ooc,
                CA.diff_time, COALESCE(CA.diff_time, 0) + COALESCE(CS.diff_time, 0),
                CA.ext_time, COALESCE(CA.ext_time, 0) + COALESCE(CS.ext_time, 0),
                S.name
            FROM contest_accounts CA
            LEFT JOIN contest_sites CS ON CS.contest_id = CA.contest_id AND CS.site_id = CA.site_id
            LEFT JOIN sites S ON S.id = CA.site_id
            WHERE CA.contest_id = ? AND CA.account_id = ?~, undef,
            $cid, $uid);
        $user->{diff_time} ||= 0;
        $user->{ext_time} ||= 0;
        $is_jury ||= $is_root;
    }
    else {
        $user->{anonymous_id} = $dbh->selectrow_array(q~
            SELECT id FROM accounts WHERE login = ?~, undef,
            $cats::anonymous_login);
        $user->{is_participant} = $contest->is_practice;
    }
    $user->{is_jury} = $is_jury;
    $user->{is_local} = $user->{is_participant} && !$user->{is_remote} && !$user->{is_ooc};
    if ($contest->{is_hidden} && !$user->{is_participant} && !$is_root) {
        # If user tries to look at a hidden contest, show training instead.
        $contest->load(0);
        $settings->{contest_id} = $cid = $contest->{id};
    }
}

sub initialize {
    my ($p) = @_;
    $Storable::canonical = 1;
    CATS::Messages::init;
    $t = undef;
    init_user($p);
    init_contest($p);
}

1;
