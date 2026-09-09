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


class CControllerAuthenticationUpdate extends CController {

	/**
	 * @var CControllerResponseRedirect
	 */
	private $response;

	protected function init() {
		$this->response = new CControllerResponseRedirect((new CUrl('zabbix.php'))
			->setArgument('action', 'authentication.edit')
			->getUrl()
		);
	}

	protected function checkInput() {
		// LDAP and SAML authentication were removed from this build; only internal and HTTP authentication remain.
		$fields = [
			'form_refresh' =>				'int32',
			'db_authentication_type' =>		'int32',
			'authentication_type' =>		'in '.ZBX_AUTH_INTERNAL,
			'http_case_sensitive' =>		'in '.ZBX_AUTH_CASE_INSENSITIVE.','.ZBX_AUTH_CASE_SENSITIVE,
			'http_auth_enabled' =>			'in '.ZBX_AUTH_HTTP_DISABLED.','.ZBX_AUTH_HTTP_ENABLED,
			'http_login_form' =>			'in '.ZBX_AUTH_FORM_ZABBIX.','.ZBX_AUTH_FORM_HTTP,
			'http_strip_domains' =>			'db config.http_strip_domains'
		];

		$ret = $this->validateInput($fields);

		if (!$ret) {
			$this->response->setFormData($this->getInputAll());
			$this->setResponse($this->response);
		}

		return $ret;
	}

	/**
	 * Validate default authentication. Do not allow user to change default authentication to LDAP if LDAP is not
	 * configured.
	 *
	 * @return bool
	 */
	private function validateDefaultAuth() {
		$data = [
			'ldap_configured' => ZBX_AUTH_LDAP_DISABLED,
			'authentication_type' => ZBX_AUTH_INTERNAL
		];
		$this->getInputs($data, array_keys($data));

		$is_valid = ($data['authentication_type'] != ZBX_AUTH_LDAP
				|| $data['ldap_configured'] == ZBX_AUTH_LDAP_ENABLED);

		if (!$is_valid) {
			$this->response->setMessageError(_s('Incorrect value for field "%1$s": %2$s.', 'authentication_type',
				_('LDAP is not configured')
			));
		}

		return $is_valid;
	}

	/**
	 * Validate is user allowed to change configuration.
	 *
	 * @return bool
	 */
	protected function checkPermissions() {
		return $this->getUserType() == USER_TYPE_SUPER_ADMIN;
	}

	protected function doAction() {
		$auth_valid = $this->validateDefaultAuth();

		if (!$auth_valid) {
			$this->response->setFormData($this->getInputAll());
			$this->setResponse($this->response);

			return;
		}

		// LDAP and SAML authentication were removed from this build; the ldap_*/saml_* config columns are left
		// untouched (not part of $fields) so an authentication settings save never overwrites their stored values.
		$config = select_config();
		$fields = [
			'authentication_type' => ZBX_AUTH_INTERNAL,
			'http_auth_enabled' => ZBX_AUTH_HTTP_DISABLED
		];

		if ($this->getInput('http_auth_enabled', ZBX_AUTH_HTTP_DISABLED) == ZBX_AUTH_HTTP_ENABLED) {
			$fields += [
				'http_case_sensitive' => 0,
				'http_login_form' => 0,
				'http_strip_domains' => ''
			];
		}

		$data = array_merge($config, $fields);
		$this->getInputs($data, array_keys($fields));
		$data = array_diff_assoc($data, $config);

		if ($data) {
			$result = update_config($data);

			if ($result) {
				if (array_key_exists('authentication_type', $data)) {
					$this->invalidateSessions();
				}

				$this->response->setMessageOk(_('Authentication settings updated'));
				add_audit(AUDIT_ACTION_UPDATE, AUDIT_RESOURCE_ZABBIX_CONFIG, _('Authentication method changed'));
			}
			else {
				$this->response->setFormData($this->getInputAll());
				$this->response->setMessageError(_('Cannot update authentication'));
			}
		}
		else {
			$this->response->setMessageOk(_('Authentication settings updated'));
		}

		$this->setResponse($this->response);
	}

	/**
	 * Mark all active GROUP_GUI_ACCESS_INTERNAL sessions, except current user sessions, as ZBX_SESSION_PASSIVE.
	 *
	 * @return bool
	 */
	private function invalidateSessions() {
		$result = true;
		$internal_auth_user_groups = API::UserGroup()->get([
			'output' => [],
			'filter' => [
				'gui_access' => GROUP_GUI_ACCESS_INTERNAL
			],
			'preservekeys' => true
		]);

		$internal_auth_users = API::User()->get([
			'output' => [],
			'usrgrpids' => array_keys($internal_auth_user_groups),
			'preservekeys' => true
		]);
		unset($internal_auth_users[CWebUser::$data['userid']]);

		if ($internal_auth_users) {
			DBstart();
			$result = DB::update('sessions', [
				'values' => ['status' => ZBX_SESSION_PASSIVE],
				'where' => ['userid' => array_keys($internal_auth_users)]
			]);
			$result = DBend($result);
		}

		return $result;
	}
}
