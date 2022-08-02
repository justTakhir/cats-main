package CATS::ApiJudge;

use strict;
use warnings;

use JSON::XS;
use Math::BigInt;
use MIME::Base64;

use CATS::Constants;
use CATS::DB;
use CATS::Globals qw($sid);
use CATS::Job;
use CATS::JudgeDB;
use CATS::RouteParser;
use CATS::Testset;

# DE bitmap cache may return bigints.
sub Math::BigInt::TO_JSON { $_[0]->bstr }

my $bad_sid = { error => 'bad sid' };
my $stolen = { error => 'stolen' };

sub _hex { join ' ', length($_[0]), map sprintf('%02X', $_), unpack '(C1)10', $_[0]; }

sub bad_judge {
    $sid && CATS::JudgeDB::get_judge_id($sid) ? 0 : $_[0]->print_json($bad_sid);
}

sub get_judge_id {
    my ($p) = @_;
    my $id = $sid && CATS::JudgeDB::get_judge_id($sid) or return $p->print_json($bad_sid);

    my $old_version = $dbh->selectrow_array(q~
        SELECT version FROM judges WHERE id = ?~, undef,
        $id);
    if (($p->{version} // '') ne ($old_version // '')) {
        $dbh->do(q~
            UPDATE judges SET version = ? WHERE id = ?~, undef, $p->{version}, $id);
        $dbh->commit;
    }
    $p->print_json({ id => $id });
}

sub get_DEs {
    my ($p) = @_;
    bad_judge($p) and return -1;

    $p->print_json(CATS::JudgeDB::get_DEs(@_));
}

sub get_problem {
    my ($p) = @_;
    bad_judge($p) and return -1;

    $p->print_json({ problem => CATS::JudgeDB::get_problem($p->{pid}) });
}

sub get_problem_snippets {
    my ($p) = @_;
    bad_judge($p) and return -1;

    $p->print_json({ snippets => CATS::JudgeDB::get_problem_snippets($p->{pid}) });
}

sub get_problem_tags {
    my ($p) = @_;
    bad_judge($p) and return -1;

    $p->print_json({ tags => CATS::JudgeDB::get_problem_tags($p->{pid}, $p->{cid}, $p->{aid}) });
}

sub get_snippet_text {
    my ($p) = @_;
    bad_judge($p) and return -1;

    $p->print_json({
        texts => CATS::JudgeDB::get_snippet_text($p->{pid}, $p->{cid}, $p->{uid}, $p->{name}) });
}

sub get_problem_sources {
    my ($p) = @_;
    bad_judge($p) and return -1;

    $p->print_json({ sources => CATS::JudgeDB::get_problem_sources($p->{pid}) });
}

sub get_problem_tests {
    my ($p) = @_;
    bad_judge($p) and return -1;

    $p->print_json({ tests => CATS::JudgeDB::get_problem_tests($p->{pid}) });
}

sub is_problem_uptodate {
    my ($p) = @_;
    bad_judge($p) and return -1;

    $p->print_json({ uptodate => CATS::JudgeDB::is_problem_uptodate($p->{pid}, $p->{date}) });
}

sub save_logs {
    my ($p) = @_;
    bad_judge($p) and return -1;

    $p->{job_id} or return $p->print_json({ error => 'No job_id' });

    my $upload = $p->make_upload('dump');
    my $dump = $upload ? $upload->content : $p->{dump};
    CATS::JudgeDB::save_logs($p->{job_id}, $dump);
    $dbh->commit;

    $p->print_json({ ok => 1 });
}

sub set_request_state {
    my ($p) = @_;
    my $judge_id = $sid && CATS::JudgeDB::get_judge_id($sid)
        or return $p->print_json($bad_sid);

    my $result = CATS::JudgeDB::set_request_state({
        jid         => $judge_id,
        req_id      => $p->{req_id},
        state       => $p->{state},
        job_id      => $p->{job_id},
        contest_id  => $p->{contest_id},
        problem_id  => $p->{problem_id},
        failed_test => $p->{failed_test},
    });

    $p->print_json({ result => $result // 0 });
}

our @create_job_params = qw(problem_id state parent_id req_id contest_id);

sub is_set_req_state_allowed {
    my ($p) = @_;
    bad_judge($p) and return -1;

    my ($parent_id, $allow_set_req_state) =
        CATS::JudgeDB::is_set_req_state_allowed($p->{job_id}, $p->{force});
    $p->print_json({ parent_id => $parent_id, allow_set_req_state => $allow_set_req_state });
}

sub create_splitted_jobs {
    my ($p) = @_;
    bad_judge($p) and return -1;

    CATS::Job::create_splitted_jobs($p->{job_type}, $p->{testsets}, {
        map { $_ => $p->{$_} } @create_job_params
    });
    $dbh->commit;

    $p->print_json({ ok => 1 });
}

sub cancel_all {
    my ($p) = @_;
    bad_judge($p) and return -1;

    CATS::Job::cancel_all($p->{req_id});
    $p->print_json({ ok => 1 });
}

sub create_job {
    my ($p) = @_;

    my $judge_id = $sid && CATS::JudgeDB::get_judge_id($sid)
        or return $p->print_json($bad_sid);

    my $job_id = CATS::Job::create($p->{job_type}, {
        judge_id => $judge_id,
        map { $_ => $p->{$_} } @create_job_params
    });
    $dbh->commit;

    $p->print_json({ job_id => $job_id });
}

sub finish_job {
    my ($p) = @_;
    bad_judge($p) and return -1;

    $p->print_json({ result => CATS::Job::finish($p->{job_id}, $p->{job_state}) // 0 });
}

sub select_request {
    my ($p) = @_;

    $sid or return $p->print_json($bad_sid);

    my @required_fields = ('de_version', map "de_bits$_", 1..$cats::de_req_bitfields_count);
    return $p->print_json({ error => 'bad request' }) if grep !defined $p->{$_}, @required_fields;

    my $response = {};
    (
        $response->{was_pinged}, $response->{pin_mode}, my $jid, my $time_since_alive
    ) = $dbh->selectrow_array(q~
        SELECT 1 - J.is_alive, J.pin_mode, J.id,
            CAST(CURRENT_TIMESTAMP - J.alive_date AS DOUBLE PRECISION)
        FROM judges J INNER JOIN accounts A ON J.account_id = A.id WHERE A.sid = ?~, undef,
        $sid) or return print_json($bad_sid);

    $response->{request} = CATS::JudgeDB::select_request({
        jid              => $jid,
        was_pinged       => $response->{was_pinged},
        pin_mode         => $response->{pin_mode},
        time_since_alive => $time_since_alive,
        (map { $_ => $p->{$_} } @required_fields),
    });

    $p->print_json($response->{request} && $response->{request}->{error} ?
        { error => $response->{request}->{error} } : $response);
}

sub delete_req_details {
    my ($p) = @_;

    my $judge_id = $sid && CATS::JudgeDB::get_judge_id($sid)
        or return $p->print_json($bad_sid);

    $p->print_json({
        result => CATS::JudgeDB::delete_req_details($p->{req_id}, $judge_id, $p->{job_id}) // 0 });
}

sub get_tests_req_details {
    my ($p) = @_;
    bad_judge($p) and return -1;

    $p->print_json({ req_details => CATS::JudgeDB::get_tests_req_details($p->{req_id}) });
}

our %req_details_fields = (
    job_id => integer,
    output => undef,
    output_size => integer,
    req_id => integer,
    test_rank => integer,
    result => integer,
    time_used => fixed,
    memory_used => integer,
    disk_used => integer,
    checker_comment => str,
    points => integer,
);

sub insert_req_details {
    my ($p) = @_;

    my $judge_id = $sid && CATS::JudgeDB::get_judge_id($sid)
        or return $p->print_json($bad_sid);

    my %filtered_params =
        map { exists $p->{$_} ? ($_ => $p->{$_}) : () } keys %req_details_fields;
    if (exists $filtered_params{output}) {
        $filtered_params{output} = MIME::Base64::decode_base64($filtered_params{output});
    }

    $p->print_json({ result =>
        CATS::JudgeDB::insert_req_details($p->{job_id}, %filtered_params, judge_id => $judge_id) // 0 });
}

sub save_input_test_data {
    my ($p) = @_;
    bad_judge($p) and return -1;

    my $input_decoded = MIME::Base64::decode_base64($p->{input});
    CATS::JudgeDB::save_input_test_data(
        $p->{problem_id}, $p->{test_rank}, $input_decoded, $p->{input_size}, $p->{hash});

    $p->print_json({ ok => 1 });
}

sub save_answer_test_data {
    my ($p) = @_;
    bad_judge($p) and return -1;

    my $answer_decoded = MIME::Base64::decode_base64($p->{answer});
    CATS::JudgeDB::save_answer_test_data(
        $p->{problem_id}, $p->{test_rank}, $answer_decoded, $p->{answer_size});

    $p->print_json({ ok => 1 });
}

sub save_problem_snippets {
    my ($p) = @_;
    bad_judge($p) and return -1;
    my ($n, $t) = @$p{qw(name text)};
    @$n == @$t or return -1;

    my $snippets = { map { $n->[$_] => $t->[$_] } 0 .. $#$n };
    CATS::JudgeDB::save_problem_snippets(
        $p->{problem_id}, $p->{contest_id}, $p->{account_id}, $snippets);

    $p->print_json({ ok => 1 });
}

sub get_testset {
    my ($p) = @_;
    bad_judge($p) and return -1;

    my %testset = CATS::Testset::get_testset($dbh, $p->{table}, $p->{id}, $p->{update});

    $p->print_json({ testset => \%testset });
}

1;
