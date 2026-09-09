<?php
/*
** Zabbix
** Copyright (C) 2001-2025 Zabbix SIA
**
** This program is free software; you can redistribute it and/or modify
** it under the terms of the GNU General Public License as published by
** the Free Software Foundation; either version 2 of the License, or
** (at your option) any later version.
**
** This program is distributed in the hope that it will be useful,
** but WITHOUT ANY WARRANTY; without even the implied warranty of
** MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
** GNU General Public License for more details.
**
** You should have received a copy of the GNU General Public License
** along with this program; if not, write to the Free Software
** Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
**/


/**
 * @var CView $this
 */

$this->includeJsFile('administration.authentication.edit.js.php');

// Authentication general fields and HTTP authentication fields.
// LDAP and SAML authentication options were removed from this build; only internal authentication remains.
$auth_tab = (new CFormList('list_auth'))
	->addRow(new CLabel(_('Default authentication'), 'authentication_type'),
		(new CRadioButtonList('authentication_type', (int) $data['authentication_type']))
			->setAttribute('autofocus', 'autofocus')
			->addValue(_x('Internal', 'authentication'), ZBX_AUTH_INTERNAL)
			->setModern(true)
			->removeId()
	);

// HTTP authentication fields.
$http_tab = (new CFormList('list_http'))
	->addRow(new CLabel(_('Enable HTTP authentication'), 'http_auth_enabled'),
		(new CCheckBox('http_auth_enabled', ZBX_AUTH_HTTP_ENABLED))
			->setChecked($data['http_auth_enabled'] == ZBX_AUTH_HTTP_ENABLED)
			->setUncheckedValue(ZBX_AUTH_HTTP_DISABLED)
	)
	->addRow(new CLabel(_('Default login form'), 'label-http-login-form'),
		(new CSelect('http_login_form'))
			->setFocusableElementId('label-http-login-form')
			->setValue($data['http_login_form'])
			->addOptions(CSelect::createOptionsFromArray([
				ZBX_AUTH_FORM_ZABBIX => _('Zabbix login form'),
				ZBX_AUTH_FORM_HTTP => _('HTTP login form')
			]))
			->setDisabled($data['http_auth_enabled'] != ZBX_AUTH_HTTP_ENABLED)
	)
	->addRow(new CLabel(_('Remove domain name'), 'http_strip_domains'),
		(new CTextBox('http_strip_domains', $data['http_strip_domains']))
			->setEnabled($data['http_auth_enabled'])
			->setWidth(ZBX_TEXTAREA_STANDARD_WIDTH)
	)
	->addRow(new CLabel(_('Case sensitive login'), 'http_case_sensitive'),
		(new CCheckBox('http_case_sensitive', ZBX_AUTH_CASE_SENSITIVE))
			->setChecked($data['http_case_sensitive'] == ZBX_AUTH_CASE_SENSITIVE)
			->setEnabled($data['http_auth_enabled'] == ZBX_AUTH_HTTP_ENABLED)
			->setUncheckedValue(ZBX_AUTH_CASE_INSENSITIVE)
	);

$selected_tab = $data['form_refresh'] ? get_cookie('tab', 0) : 0;
(new CWidget())
	->setTitle(_('Authentication'))
	->addItem((new CForm())
		->addVar('form_refresh', $data['form_refresh'] + 1)
		->addVar('action', $data['action_submit'])
		->addVar('db_authentication_type', $data['db_authentication_type'])
		->setName('form_auth')
		->setAttribute('aria-labelledby', ZBX_STYLE_PAGE_TITLE)
		->disablePasswordAutofill()
		->addItem((new CTabView())
			->setSelected($selected_tab)
			->addTab('auth', _('Authentication'), $auth_tab)
			->addTab('http', _('HTTP settings'), $http_tab)
			->setFooter(makeFormFooter(
				new CSubmit('update', _('Update'))
			))
	))
	->show();
