"""nginx(docker/web/conf/nginx.conf)の配信と、外から見えてはいけないファイル。

静的ファイル、PHPの処理、ソースツリー内の非公開のはずのファイルの扱い。
"""
import pytest

from zbxclient import page_problems


@pytest.mark.parametrize(
    "path,content_type",
    [
        ("assets/styles/blue-theme.css", "text/css"),
        ("js/common.js", "application/javascript"),
        ("jsLoader.php?lang=en_US", "application/javascript"),
    ],
)
def test_static_assets_are_served_with_the_right_type(anonymous, path, content_type):
    resp = anonymous.get(path)

    assert resp.status == 200
    assert resp.content_type in (content_type, "text/javascript")


def test_php_files_run_and_are_never_returned_as_source(anonymous):
    resp = anonymous.get("index.php")

    assert "<?php" not in resp.text


def _is_not_the_file(resp):
    """拒否(403/404)か、ファイルの中身ではなくログイン画面(index.php)が返っていること。

    5.0 の nginx は `try_files $uri $uri/ /index.php` なので、存在しない(PHP以外の)パスは404ではなく
    index.php(=ログイン画面、HTTP 200)になる。公式イメージと同じ作りで、ファイルの中身が漏れるわけではない。"""
    return resp.status in (403, 404) or ('name="password"' in resp.text and "<?php" not in resp.text)


def test_dotfiles_are_denied(anonymous):
    assert _is_not_the_file(anonymous.get(".htaccess"))


@pytest.mark.parametrize(
    "path",
    [
        "conf/zabbix.conf.php",
        "conf/zabbix.conf.php.example",
        "include/defines.inc.php",
        "app/controllers/CControllerModuleScan.php",
        "vendor/autoload.php",
        "vendor/composer/installed.json",
        "locale/ja/LC_MESSAGES/frontend.po",
        "composer.json",
        "composer.lock",
        "phpunit.xml.dist",
        "tests/",
    ],
)
def test_internal_files_are_not_exposed(anonymous, path):
    """設定・同梱ライブラリの一覧(版が分かる)・コントローラーのソースは、外から取れない/実行できない。

    docker/web/conf/nginx.conf に /app /conf /include /local /locale /vendor と composer.json/lock の
    拒否ルールが無かった間は、composer.json/lock と vendor/composer/installed.json が同梱ライブラリの版を
    丸ごと返し、PHPの内部ファイルは単体で実行されて500や空の200を返していた。
    5.0 のイメージには ui/vendor・composer.json/lock・ui/tests は入らない(.dockerignore)ので、それらは拒否ルールの
    有無に関わらず404になる。ここで本当に効いているのは app/ conf/ include/ locale/ の4つ。
    """
    resp = anonymous.get(path)

    assert _is_not_the_file(resp), f"/{path} answered HTTP {resp.status}"


@pytest.mark.parametrize("path", ["applications.php", "conf.import.php", "host_prototypes.php", "hosts.php"])
def test_top_level_pages_are_not_swallowed_by_the_deny_rules(anonymous, path):
    """拒否ルール(/app /conf /include ...)は先頭一致の `^~`。名前が似た最上位のページ(applications.php は /app と、
    conf.import.php は /conf と接頭辞が同じ)が巻き込まれず、ログイン前でも普通に画面(ログインを促す表示)を返す。"""
    resp = anonymous.get(path)

    assert resp.status == 200, f"/{path} answered HTTP {resp.status}"
    assert "Fatal error" not in resp.text


@pytest.mark.parametrize("path", ["include/classes/core/CAutoloader.php", "app/controllers/CControllerProblemView.php"])
def test_php_internals_answer_404_not_500(anonymous, path):
    """PHPの内部ファイルを直接取りに行くと、単体で実行されて500になる(拒否ルールが無いとき)。404であること。"""
    assert anonymous.get(path).status == 404


@pytest.mark.parametrize("directory", ["local/conf/", "modules/"])
def test_directories_are_not_listed(anonymous, directory):
    assert _is_not_the_file(anonymous.get(directory))


def test_the_setup_wizard_is_not_reachable_once_configured(anonymous):
    resp = anonymous.get("setup.php")

    assert "Welcome to" not in resp.visible_text
    assert "Check of pre-requisites" not in resp.visible_text


def test_a_missing_page_is_a_clean_404(anonymous):
    resp = anonymous.get("no-such-page.php")

    assert resp.status == 404
    assert "Fatal error" not in resp.text


def test_a_missing_php_action_does_not_crash(admin):
    resp = admin.get("zabbix.php", params={"action": "no.such.action"})

    assert resp.status in (200, 404)
    assert "Fatal error" not in resp.text and "Stack trace" not in resp.text


def test_index_http_entry_point_does_not_crash(anonymous):
    """HTTP認証の入口(未設定のとき)。PHPのエラーではなく、ログイン画面への転送か普通の応答で返る。"""
    resp = anonymous.get("index_http.php", follow=False)

    assert resp.status < 500
    assert "Fatal error" not in resp.text and "Stack trace" not in resp.text
