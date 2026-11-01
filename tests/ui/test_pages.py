"""管理画面の主要ページが、PHPのエラーもZabbixのエラー枠も出さずに表示できる。

各ページはPHPの別々の拡張(gd・mbstring・bcmath・xml・gettext・sockets・mysqli)とフロントエンド
同梱ライブラリを通る。PHPを差し替えたり、ui/vendor/ のライブラリを上げたりしたとき、SCAは通っても
特定のページだけが壊れる、ということが起こる(symfony/yamlの件がそうだった)。ここで広く浅く掃く。
"""
import json

import pytest

from zbxclient import page_problems

# (ページ, <title>に含まれるはずの文字列)
LIST_AND_SETTINGS_PAGES = [
    # 監視(5.0 は画面の半分が昔ながらの *.php、残りが zabbix.php?action=)
    # dashboard.view だけだとダッシュボード一覧へ転送される(最後に開いたダッシュボードが無いとき)ので、IDを指定する。
    ("zabbix.php?action=dashboard.view&dashboardid=1", "Dashboard"),
    ("zabbix.php?action=dashboard.list", "Dashboards"),
    ("zabbix.php?action=problem.view", "Problems"),
    ("zabbix.php?action=host.view", "Hosts"),
    ("overview.php", "Overview"),
    ("zabbix.php?action=latest.view", "Latest data"),
    # 画面が1つも無いと screenconf.php(設定側)へ転送される。
    ("screens.php", "Configuration of screens"),
    ("slides.php", "Configuration of slide shows"),
    ("zabbix.php?action=map.view", "Configuration of network maps"),
    ("zabbix.php?action=discovery.view", "Status of discovery"),
    ("srv_status.php", "Services"),
    # インベントリ
    ("hostinventoriesoverview.php", "Host inventory overview"),
    ("hostinventories.php", "Host inventory"),
    # レポート
    ("zabbix.php?action=report.status", "System information"),
    ("report2.php", "Availability report"),
    ("toptriggers.php", "100 busiest triggers"),
    ("zabbix.php?action=auditlog.list", "Audit"),
    ("auditacts.php", "Action log"),
    ("report4.php", "Notification report"),
    # 設定
    ("hostgroups.php", "Configuration of host groups"),
    ("templates.php", "Configuration of templates"),
    ("hosts.php", "Configuration of hosts"),
    ("maintenance.php", "Configuration of maintenance periods"),
    ("actionconf.php?eventsource=0", "Configuration of actions"),
    ("correlation.php", "Event correlation rules"),
    ("discoveryconf.php", "Configuration of discovery rules"),
    ("services.php", "Configuration of services"),
    ("screenconf.php", "Configuration of screens"),
    ("slideconf.php", "Configuration of slide shows"),
    ("sysmaps.php", "Configuration of network maps"),
    # 管理
    ("zabbix.php?action=gui.edit", "Configuration of GUI"),
    ("zabbix.php?action=autoreg.edit", "Autoregistration"),
    ("zabbix.php?action=housekeeping.edit", "Configuration of housekeeping"),
    ("zabbix.php?action=image.list", "Configuration of images"),
    ("zabbix.php?action=iconmap.list", "Configuration of icon mapping"),
    ("zabbix.php?action=regex.list", "Configuration of regular expressions"),
    ("zabbix.php?action=macros.edit", "Configuration of macros"),
    ("zabbix.php?action=valuemap.list", "Configuration of value mapping"),
    ("zabbix.php?action=workingtime.edit", "Configuration of working time"),
    ("zabbix.php?action=trigseverity.edit", "Configuration of trigger severities"),
    ("zabbix.php?action=trigdisplay.edit", "Configuration of trigger displaying options"),
    ("zabbix.php?action=module.list", "Modules"),
    ("zabbix.php?action=miscconfig.edit", "Other configuration parameters"),
    ("zabbix.php?action=proxy.list", "Configuration of proxies"),
    ("zabbix.php?action=authentication.edit", "Configuration of authentication"),
    ("zabbix.php?action=usergroup.list", "Configuration of user groups"),
    ("zabbix.php?action=user.list", "Configuration of users"),
    ("zabbix.php?action=mediatype.list", "Configuration of media types"),
    ("zabbix.php?action=script.list", "Configuration of scripts"),
    ("queue.php", "Queue"),
    ("zabbix.php?action=userprofile.edit", "User profile"),
]


@pytest.mark.parametrize("page,title", LIST_AND_SETTINGS_PAGES, ids=[p for p, _ in LIST_AND_SETTINGS_PAGES])
def test_page_renders_cleanly(admin, page, title):
    resp = admin.get(page)

    assert page_problems(resp) == []
    assert title in resp.title


def test_the_footer_shows_the_5_0_version(admin):
    resp = admin.get("zabbix.php", params={"action": "dashboard.list"})

    assert "Zabbix 5.0." in resp.visible_text


# -- 実データのある画面 ----------------------------------------------------------------------
# conftest.py の seed が作ったホスト・テンプレート・アイテム・トリガー・グラフを、一覧と編集フォームで開く。


def test_the_host_list_shows_the_seeded_host(admin, seed):
    resp = admin.get("hosts.php", params={"filter_host": seed.prefix, "filter_set": "1"})

    assert page_problems(resp) == []
    assert f"{seed.prefix} host" in resp.text


def test_the_template_list_shows_the_seeded_template(admin, seed):
    resp = admin.get("templates.php", params={"filter_name": seed.prefix, "filter_set": "1"})

    assert page_problems(resp) == []
    assert f"{seed.prefix} template" in resp.text


def test_the_host_group_form_opens(admin, seed):
    resp = admin.get("hostgroups.php", params={"form": "update", "groupid": seed.groupid})

    assert page_problems(resp) == []
    assert f"{seed.prefix} group" in resp.text


@pytest.mark.parametrize(
    "page,params,expected",
    [
        ("items.php", {"filter_hostids[]": "{hostid}", "filter_set": "1"}, "CPU load"),
        ("items.php", {"hostid": "{hostid}", "form": "update", "itemid": "{itemid}"}, "zbx5ui.cpu"),
        ("triggers.php", {"filter_hostids[]": "{hostid}", "filter_set": "1"}, "CPU load is too high"),
        ("triggers.php", {"hostid": "{hostid}", "form": "update", "triggerid": "{triggerid}"}, "CPU load is too high"),
        ("graphs.php", {"filter_hostids[]": "{hostid}", "filter_set": "1"}, "CPU load graph"),
        ("graphs.php", {"hostid": "{hostid}", "form": "update", "graphid": "{graphid}"}, "CPU load graph"),
        ("applications.php", {"filter_hostids[]": "{hostid}", "filter_set": "1"}, "Applications"),
        ("httpconf.php", {"filter_hostids[]": "{hostid}", "filter_set": "1"}, "Web monitoring"),
        ("host_discovery.php", {"filter_hostids[]": "{hostid}", "filter_set": "1"}, "Discovery rules"),
    ],
    ids=["items-list", "item-form", "triggers-list", "trigger-form", "graphs-list", "graph-form", "applications-list",
         "web-list", "lld-list"],
)
def test_configuration_pages_show_the_seeded_entity(admin, seed, page, params, expected):
    values = {"hostid": seed.hostid, "itemid": seed.itemid, "triggerid": seed.triggerid, "graphid": seed.graphid}
    params = {k: v.format(**values) for k, v in params.items()}

    resp = admin.get(page, params=params)

    assert page_problems(resp) == []
    assert expected in resp.text


def test_the_host_edit_form_opens(admin, seed):
    resp = admin.get("hosts.php", params={"form": "update", "hostid": seed.hostid})

    assert page_problems(resp) == []
    assert seed.host_host in resp.text


def test_the_map_editor_opens(admin, seed):
    resp = admin.get("sysmap.php", params={"sysmapid": seed.sysmapid})

    assert page_problems(resp) == []
    assert f"{seed.prefix} map" in resp.text


def test_the_map_view_opens(admin, seed):
    resp = admin.get("zabbix.php", params={"action": "map.view", "sysmapid": seed.sysmapid})

    assert page_problems(resp) == []
    assert f"{seed.prefix} map" in resp.text


def test_the_graph_view_lists_the_seeded_graph(admin, seed):
    """グラフ画面はグラフの一覧をJSON(charts.view.json)で取り、画像(chart2.php)を並べる。"""
    resp = admin.get(
        "zabbix.php",
        params={"action": "charts.view.json", "filter_hostids[]": seed.hostid},
    )

    assert resp.status == 200 and resp.content_type == "application/json"
    graphs = json.loads(resp.body)["charts"]
    assert [str(chart["chartid"]) for chart in graphs] == [seed.graphid]
    assert graphs[0]["src"] == "chart2.php"
