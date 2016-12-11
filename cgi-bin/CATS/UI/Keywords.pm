package CATS::UI::Keywords;

use strict;
use warnings;

use CATS::DB;
use CATS::ListView qw(init_listview_template order_by define_columns attach_listview);
use CATS::Misc qw(
    $t $is_jury $is_root
    init_template msg res_str url_f references_menu);
use CATS::Web qw(param url_param);

sub fields () { qw(name_ru name_en code) }

sub edit_frame
{
    init_template('keywords_edit.html.tt');
    my $kwid = url_param('edit');
    my $kw = $kwid ? $dbh->selectrow_hashref(q~
        SELECT * FROM keywords WHERE id = ?~, undef, $kwid) : {};
    $t->param(%$kw, href_action => url_f('keywords'));
}

sub edit_save
{
    my $kwid = param('id');
    my %p = map { $_ => (param($_) || '') } fields();

    $p{name_en} ne '' && 0 == grep(length $p{$_} > 200, fields())
        or return msg(1084);

    if ($kwid) {
        my $set = join ', ', map "$_ = ?", fields();
        $dbh->do(qq~
            UPDATE keywords SET $set WHERE id = ?~, undef,
            @p{fields()}, $kwid);
        $dbh->commit;
    }
    else {
        my $field_names = join ', ', fields();
        $dbh->do(qq~
            INSERT INTO keywords (id, $field_names) VALUES (?, ?, ?, ?)~, undef,
            new_id, @p{fields()});
        $dbh->commit;
    }
}

sub keywords_frame
{
    if ($is_root) {
        if (defined url_param('delete')) {
            my $kwid = url_param('delete');
            $dbh->do(q~DELETE FROM keywords WHERE id = ?~, {}, $kwid);
            $dbh->commit;
        }

        defined url_param('new') || defined url_param('edit') and return edit_frame;
    }
    init_listview_template('keywords', 'keywords', 'keywords.html.tt');

    $is_root && defined param('edit_save') and edit_save;

    define_columns(url_f('keywords'), 0, 0, [
        { caption => res_str(625), order_by => '2', width => '30%' },
        { caption => res_str(636), order_by => '3', width => '30%' },
        { caption => res_str(637), order_by => '4', width => '30%' },
        { caption => res_str(643), order_by => '5', width => '10%' },
    ]);

    my $c = $dbh->prepare(q~
        SELECT k.id AS kwid, k.code, k.name_ru, k.name_en,
            (SELECT COUNT(*) FROM problem_keywords pk WHERE pk.keyword_id = k.id) AS ref_count
        FROM keywords k ~ . order_by);
    $c->execute;

    my $fetch_record = sub {
        my $row = $_[0]->fetchrow_hashref or return ();
        return (
            %$row,
            href_edit=> url_f('keywords', edit => $row->{kwid}),
            href_delete => url_f('keywords', 'delete' => $row->{kwid}),
            href_view_problems => url_f('problems', kw => $row->{kwid}, ($is_jury ? (link => 1) : ())),
        );
    };

    attach_listview(url_f('keywords'), $fetch_record, $c);

    $t->param(submenu => [ references_menu('keywords') ], editable => $is_root) if $is_jury;
}

1;
