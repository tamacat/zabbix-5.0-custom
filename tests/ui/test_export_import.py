"""構成のエクスポート/インポート(XML・JSON)。

5.0 の画面のエクスポートはXMLだけ(export.*.xml)。YAMLは 5.4 から、画面からのJSONも 5.4 以降で、5.0 の
書き出し側にはXMLとJSONのライターがあり、JSONはAPI(configuration.export)からだけ使える。インポートは
画面(conf.import.php、ファイルのアップロード)とAPI(configuration.import)のどちらも、XMLとJSONを読める。

XMLの書き出しはPHPのxmlwriter、読み込みはsimplexml_load_string()(CXmlImportReader.php)を通る。
zabbix-webのPHPを --enable-simplexml 無しでビルドしていた間は、XMLのインポートだけが
「Call to undefined function」で落ちた。ここでは画面のエクスポートボタンと同じ経路(zabbix.php?action=export.*.xml)と、
画面のインポート(ファイルのアップロード)を叩く。
"""
import json
import secrets
import xml.etree.ElementTree as ET

import pytest

from conftest import PREFIX
from zbxclient import page_problems


def _export_xml(admin, action, key, ids):
    return admin.post(
        "zabbix.php",
        {"action": action, key: ids, "backurl": "zabbix.php?action=dashboard.view", "sid": admin.sid()},
    )


def _xml_root(body):
    root = ET.fromstring(body)
    assert root.tag == "zabbix_export"
    return root


@pytest.fixture
def mediatypeid(api):
    return api.call("mediatype.get", {"output": ["mediatypeid"], "filter": {"name": "Email"}})[0]["mediatypeid"]


def test_export_template_xml(admin, seed):
    resp = _export_xml(admin, "export.templates.xml", "templates[]", [seed.templateid])

    assert resp.status == 200
    assert resp.content_type == "text/xml"
    assert "zbx_export_templates.xml" in resp.headers["Content-Disposition"]
    assert seed.template_host in resp.text
    assert "zbx5ui.cpu" in resp.text
    root = _xml_root(resp.body)
    assert root.findtext("version") == "5.0"
    assert [t.findtext("template") for t in root.find("templates")] == [seed.template_host]


def test_export_host_xml(admin, seed):
    resp = _export_xml(admin, "export.hosts.xml", "hosts[]", [seed.hostid])

    assert resp.status == 200
    assert resp.content_type == "text/xml"
    assert [h.findtext("host") for h in _xml_root(resp.body).find("hosts")] == [seed.host_host]


def test_export_map_xml(admin, seed):
    resp = _export_xml(admin, "export.sysmaps.xml", "maps[]", [seed.sysmapid])

    assert resp.status == 200
    assert resp.content_type == "text/xml"
    assert f"{seed.prefix} map" in resp.text
    _xml_root(resp.body)


def test_export_media_type_xml(admin, mediatypeid):
    resp = _export_xml(admin, "export.mediatypes.xml", "mediatypeids[]", [mediatypeid])

    assert resp.status == 200
    assert resp.content_type == "text/xml"
    assert [m.findtext("name") for m in _xml_root(resp.body).find("media_types")] == ["Email"]


@pytest.mark.parametrize("fmt", ["xml", "json"])
def test_api_export_template(api, seed, fmt):
    """configuration.export(APIの書き出し)。JSONは 5.0 ではここからだけ出せる。"""
    exported = api.call("configuration.export", {"format": fmt, "options": {"templates": [seed.templateid]}})

    assert seed.template_host in exported and "zbx5ui.cpu" in exported
    if fmt == "json":
        doc = json.loads(exported)["zabbix_export"]
        assert doc["version"] == "5.0"
        assert [t["template"] for t in doc["templates"]] == [seed.template_host]
    else:
        assert _xml_root(exported.encode()).findtext("version") == "5.0"


def test_xml_export_keeps_japanese_text(admin, api, seed):
    """非ASCII(日本語)の名前がXMLで文字化けせずに往復する。"""
    name = f"{seed.prefix} 日本語のテンプレート"
    templateid = api.call("template.create", {"host": f"{seed.prefix}-jp", "name": name, "groups": [{"groupid": seed.groupid}]})[
        "templateids"
    ][0]
    try:
        resp = _export_xml(admin, "export.templates.xml", "templates[]", [templateid])

        assert _xml_root(resp.body).find("templates")[0].findtext("name") == name
    finally:
        api.call("template.delete", [templateid])


def _as_clone(fmt, exported, template_host, clone_host):
    """書き出したテンプレートを、別名の複製として取り込める文字列に直す。

    トリガーの式やグラフのアイテム参照にはテンプレート名({host:key.last()})が入っているので、名前は文字列ごと
    置き換える。5.0 の書き出しにはUUIDが無い(5.4 から)ので、複製の見分けは名前だけ。
    """
    exported = exported.replace(template_host, clone_host)
    if fmt == "xml":
        root = ET.fromstring(exported)
        template = root.find("templates")[0]
        template.find("name").text = clone_host
        return ET.tostring(root, encoding="unicode")

    doc = json.loads(exported)
    doc["zabbix_export"]["templates"][0]["name"] = clone_host
    return json.dumps(doc)


RULES = {
    "groups": {"createMissing": True},
    "templates": {"createMissing": True, "updateExisting": False},
    "applications": {"createMissing": True},
    "items": {"createMissing": True, "updateExisting": False},
    "triggers": {"createMissing": True, "updateExisting": False},
    "graphs": {"createMissing": True, "updateExisting": False},
    "templateLinkage": {"createMissing": True},
}


def _clean(api, clone_host):
    leftover = api.call("template.get", {"output": ["templateid"], "filter": {"host": clone_host}})
    if leftover:
        api.call("template.delete", [t["templateid"] for t in leftover])


@pytest.mark.parametrize("fmt", ["xml", "json"])
def test_exported_template_imports_back_through_the_api(api, seed, fmt):
    """書き出したテンプレートを別名で取り込み直すと、アイテムごと作られる(インポート側のパーサーも通る)。

    XMLのインポートはPHPの simplexml_load_string() を使う(CXmlImportReader.php)。zabbix-webのPHPを
    --enable-simplexml 無しでビルドしていた間は、ここだけが「Call to undefined function」で落ちた。
    """
    exported = api.call("configuration.export", {"format": fmt, "options": {"templates": [seed.templateid]}})
    clone_host = f"{PREFIX}{fmt}-clone"
    try:
        source = _as_clone(fmt, exported, seed.template_host, clone_host)
        assert api.call("configuration.import", {"format": fmt, "rules": RULES, "source": source}) is True

        found = api.call("template.get", {"output": ["host"], "filter": {"host": clone_host}, "selectItems": ["key_"]})
        assert [t["host"] for t in found] == [clone_host]
        assert [i["key_"] for i in found[0]["items"]] == ["zbx5ui.cpu"]
    finally:
        _clean(api, clone_host)


def _multipart(fields, filename, content):
    """ファイルアップロード(multipart/form-data)の本文。標準ライブラリだけで組む。"""
    boundary = "----zbx5ui" + secrets.token_hex(8)
    parts = []
    for name, value in fields:
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{name}"\r\n\r\n{value}\r\n'.encode())
    parts.append(
        f'--{boundary}\r\nContent-Disposition: form-data; name="import_file"; filename="{filename}"\r\n'
        "Content-Type: text/xml\r\n\r\n".encode() + content + b"\r\n"
    )
    parts.append(f"--{boundary}--\r\n".encode())
    return b"".join(parts), f"multipart/form-data; boundary={boundary}"


def test_import_page_opens(admin):
    """インポート画面(conf.import.php)。5.0 ではポップアップではなく、独立した画面。"""
    resp = admin.get("conf.import.php", params={"rules_preset": "template"})

    assert page_problems(resp) == []
    assert "Configuration import" in resp.title
    assert 'name="import_file"' in resp.text


def test_template_xml_uploaded_through_the_import_screen(admin, api, seed):
    """画面からXMLファイルをアップロードしてインポートする(ボタンと同じ経路。内部でsimplexmlを使う)。"""
    exported = _export_xml(admin, "export.templates.xml", "templates[]", [seed.templateid]).text
    clone_host = f"{PREFIX}upload-clone"
    try:
        source = _as_clone("xml", exported, seed.template_host, clone_host).encode()
        fields = [("sid", admin.sid()), ("import", "Import"), ("rules_preset", "template")]
        for rule in ("groups", "templates", "applications", "items", "triggers", "graphs", "templateLinkage"):
            fields.append((f"rules[{rule}][createMissing]", "1"))
        body, content_type = _multipart(fields, "clone.xml", source)

        resp = admin.post("conf.import.php", body, headers={"Content-Type": content_type})

        assert page_problems(resp) == []
        found = api.call("template.get", {"output": ["host"], "filter": {"host": clone_host}, "selectItems": ["key_"]})
        assert [t["host"] for t in found] == [clone_host], resp.visible_text[:300]
        assert [i["key_"] for i in found[0]["items"]] == ["zbx5ui.cpu"]
    finally:
        _clean(api, clone_host)


def test_export_of_a_missing_entity_reports_an_error_instead_of_crashing(admin):
    resp = _export_xml(admin, "export.templates.xml", "templates[]", ["99999999"])

    assert resp.status != 500
    assert "Fatal error" not in resp.text
