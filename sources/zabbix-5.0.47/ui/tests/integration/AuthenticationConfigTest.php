<?php declare(strict_types=1);

namespace Zabbix\Tests\Integration;

use PHPUnit\Framework\TestCase;
use ReflectionMethod;
use CControllerAuthenticationEdit;
use CControllerAuthenticationUpdate;
use CWebUser;

/**
 * Boundary tests for the authentication settings screen after LDAP/SAML removal [3.1][3.2][BR2.1].
 *
 * BR2.1 requires that removing LDAP/SAML support must not break any other setting on the Authentication
 * screen. The two checkInput() tests need no database and always run. The two doAction() tests exercise the
 * real select_config()/update_config() data path against a MySQL database (per unit-test-instructions.md
 * "integration test stub" guidance) and self-skip when ZBX_TEST_DB_* credentials do not point at a reachable
 * database — this sandbox has no PHP/MySQL toolchain to run them in, see code-summary.md.
 *
 * CControllerAuthenticationEdit/Update's checkInput()/doAction() are called directly via Reflection instead
 * of through the public run() dispatch: CControllerAuthenticationUpdate does not disable SID validation, so
 * run() would call access_deny() (which terminates the process) for a request with no session id — calling
 * the two lifecycle methods directly exercises the exact same production logic without that landmine.
 */
final class AuthenticationConfigTest extends TestCase {

	private static bool $db_available = false;

	/** @var array<string, mixed>|null */
	private static ?array $original_config_row = null;

	public static function setUpBeforeClass(): void {
		self::$db_available = (bool) @\DBconnect($error);
	}

	public static function tearDownAfterClass(): void {
		if (self::$db_available) {
			\DBclose();
		}
	}

	private int $ob_level_before_test = 0;

	protected function setUp(): void {
		$_REQUEST = [];
		// CWebUser::getIp() (invoked via add_audit() in CControllerAuthenticationUpdate::doAction()) requires
		// a request-like environment; the bare CLI SAPI has no REMOTE_ADDR. build-and-test found this via a
		// real TypeError, not a hypothetical — production always runs behind a real HTTP request.
		$_SERVER['REMOTE_ADDR'] = '127.0.0.1';
		// add_audit() (via doAction()) reads CWebUser::$data['userid']; the bare CLI SAPI never runs the
		// real login flow that normally populates it. A minimal stub is enough — production only reaches
		// this code path once checkPermissions() has already confirmed a real super-admin session.
		CWebUser::$data = ['userid' => 1, 'alias' => 'phpunit'];
		$this->ob_level_before_test = ob_get_level();
	}

	protected function tearDown(): void {
		// CController's constructor starts output buffering for the HTML response; a test that instantiates
		// one directly (bypassing run()) must close only the buffer(s) IT opened, not PHPUnit's own
		// (build-and-test found closing down to level 0 makes PHPUnit flag the test risky the other way).
		while (ob_get_level() > $this->ob_level_before_test) {
			ob_end_clean();
		}

		if (self::$db_available && self::$original_config_row !== null) {
			$this->restoreConfigRow(self::$original_config_row);
			self::$original_config_row = null;
		}
	}

	private function skipUnlessDbAvailable(): void {
		if (!self::$db_available) {
			self::markTestSkipped(
				'No reachable test MySQL database (ZBX_TEST_DB_HOST/.../ZBX_TEST_DB_DATABASE). Start '.
				'docker/dev-mysql (see podman-compose.yml) and rerun.'
			);
		}
	}

	private function readConfigRow(): array {
		return \DBfetch(\DBselect(
			'SELECT authentication_type,http_auth_enabled,http_login_form,http_case_sensitive,http_strip_domains,'.
				'ldap_configured,ldap_host,ldap_case_sensitive,saml_auth_enabled'.
			' FROM config'
		));
	}

	private function restoreConfigRow(array $row): void {
		\DBexecute(
			'UPDATE config SET '.
				'authentication_type='.\zbx_dbstr($row['authentication_type']).','.
				'http_auth_enabled='.\zbx_dbstr($row['http_auth_enabled']).','.
				'http_login_form='.\zbx_dbstr($row['http_login_form']).','.
				'http_case_sensitive='.\zbx_dbstr($row['http_case_sensitive']).','.
				'http_strip_domains='.\zbx_dbstr($row['http_strip_domains']).','.
				'ldap_configured='.\zbx_dbstr($row['ldap_configured']).','.
				'ldap_host='.\zbx_dbstr($row['ldap_host']).','.
				'ldap_case_sensitive='.\zbx_dbstr($row['ldap_case_sensitive']).','.
				'saml_auth_enabled='.\zbx_dbstr($row['saml_auth_enabled'])
		);
	}

	/**
	 * checkInput() must reject ZBX_AUTH_LDAP now that the LDAP option was removed from the "in ..." field
	 * rule [FR2.1] — submitting it must fail validation instead of silently falling through.
	 */
	public function testCheckInputRejectsLdapAuthenticationType(): void {
		$_REQUEST = ['authentication_type' => (string) ZBX_AUTH_LDAP];

		$controller = new CControllerAuthenticationUpdate();
		$check_input = new ReflectionMethod($controller, 'checkInput');
		$check_input->setAccessible(true);

		self::assertFalse($check_input->invoke($controller));
	}

	/**
	 * The surviving fields (internal authentication + all http_* settings) must still validate and round-trip
	 * through $this->input exactly as before the LDAP/SAML fields were removed from the field list [BR2.1].
	 */
	public function testCheckInputAcceptsInternalAuthenticationWithHttpFields(): void {
		$_REQUEST = [
			'form_refresh' => '1',
			'db_authentication_type' => (string) ZBX_AUTH_INTERNAL,
			'authentication_type' => (string) ZBX_AUTH_INTERNAL,
			'http_auth_enabled' => (string) ZBX_AUTH_HTTP_ENABLED,
			'http_login_form' => (string) ZBX_AUTH_FORM_HTTP,
			'http_case_sensitive' => (string) ZBX_AUTH_CASE_SENSITIVE,
			'http_strip_domains' => 'example.com'
		];

		$controller = new CControllerAuthenticationUpdate();
		$check_input = new ReflectionMethod($controller, 'checkInput');
		$check_input->setAccessible(true);

		self::assertTrue($check_input->invoke($controller));
		// assertEquals, not assertSame: Zabbix's CNewValidator 'in' rule does not uniformly cast every
		// matched field to int (build-and-test found authentication_type comes back as the string '0'),
		// and BR2.1's actual concern is the validated value, not CNewValidator's per-field PHP type.
		self::assertEquals(ZBX_AUTH_INTERNAL, $controller->getInput('authentication_type'));
		self::assertEquals(ZBX_AUTH_HTTP_ENABLED, $controller->getInput('http_auth_enabled'));
		self::assertSame('example.com', $controller->getInput('http_strip_domains'));
	}

	/**
	 * The read/display path (CControllerAuthenticationEdit::doAction()) must still return the internal and
	 * http_* configuration read via select_config(), unaffected by the removed LDAP/SAML tabs [BR2.1].
	 *
	 * This test never writes, so it needs no tearDown restore. It intentionally compares against
	 * select_config()'s own return value (not a fresh raw SQL read) — select_config() memoizes in a
	 * function-static variable for the lifetime of the PHP process, so comparing against a separately
	 * re-read row could spuriously fail if some earlier test in this process had already changed the
	 * database out from under that memoized copy. Comparing doAction()'s output against the exact same
	 * data source it draws from is the deterministic thing to assert.
	 */
	public function testEditActionReturnsInternalAndHttpConfig(): void {
		$this->skipUnlessDbAvailable();

		$controller = new CControllerAuthenticationEdit();
		$check_input = new ReflectionMethod($controller, 'checkInput');
		$check_input->setAccessible(true);
		self::assertTrue($check_input->invoke($controller));

		$do_action = new ReflectionMethod($controller, 'doAction');
		$do_action->setAccessible(true);
		$do_action->invoke($controller);

		$data = $controller->getResponse()->getData();
		$config_row = \select_config();

		self::assertSame((int) $config_row['authentication_type'], (int) $data['authentication_type']);
		self::assertSame((int) $config_row['http_auth_enabled'], (int) $data['http_auth_enabled']);
		self::assertSame((int) $config_row['http_login_form'], (int) $data['http_login_form']);
		self::assertSame((int) $config_row['http_case_sensitive'], (int) $data['http_case_sensitive']);
		self::assertSame($config_row['http_strip_domains'], $data['http_strip_domains']);
	}

	/**
	 * The single most important regression this migration could introduce: saving the authentication screen
	 * after LDAP/SAML removal must persist the surviving http_* fields correctly [BR2.1] while leaving the
	 * ldap_* / saml_* config columns completely untouched [Blast Radius Analysis — schema.inc.php is not
	 * modified and the app must not silently blank out that stored configuration on an unrelated save].
	 */
	public function testUpdateActionPersistsHttpFieldsWithoutTouchingLdapSamlColumns(): void {
		$this->skipUnlessDbAvailable();
		self::$original_config_row = $this->readConfigRow();
		$before = self::$original_config_row;

		// Toggle http_auth_enabled/login_form/case_sensitive/strip_domains, but resubmit the SAME
		// authentication_type as already stored, so array_diff_assoc() never includes it and
		// invalidateSessions() (which needs the full authenticated API/session stack) is never invoked.
		$new_http_login_form = ($before['http_login_form'] == ZBX_AUTH_FORM_ZABBIX)
			? ZBX_AUTH_FORM_HTTP
			: ZBX_AUTH_FORM_ZABBIX;

		$_REQUEST = [
			'form_refresh' => '1',
			'db_authentication_type' => (string) $before['authentication_type'],
			'authentication_type' => (string) $before['authentication_type'],
			'http_auth_enabled' => (string) ZBX_AUTH_HTTP_ENABLED,
			'http_login_form' => (string) $new_http_login_form,
			'http_case_sensitive' => (string) ZBX_AUTH_CASE_SENSITIVE,
			'http_strip_domains' => 'php8-migration-test.example'
		];

		$controller = new CControllerAuthenticationUpdate();
		$check_input = new ReflectionMethod($controller, 'checkInput');
		$check_input->setAccessible(true);
		self::assertTrue($check_input->invoke($controller));

		$do_action = new ReflectionMethod($controller, 'doAction');
		$do_action->setAccessible(true);
		$do_action->invoke($controller);

		$after = $this->readConfigRow();

		self::assertSame(ZBX_AUTH_HTTP_ENABLED, (int) $after['http_auth_enabled']);
		self::assertSame($new_http_login_form, (int) $after['http_login_form']);
		self::assertSame(ZBX_AUTH_CASE_SENSITIVE, (int) $after['http_case_sensitive']);
		self::assertSame('php8-migration-test.example', $after['http_strip_domains']);

		// The regression guard: ldap_*/saml_* columns must be byte-for-byte identical to before the save.
		self::assertSame($before['ldap_configured'], $after['ldap_configured']);
		self::assertSame($before['ldap_host'], $after['ldap_host']);
		self::assertSame($before['ldap_case_sensitive'], $after['ldap_case_sensitive']);
		self::assertSame($before['saml_auth_enabled'], $after['saml_auth_enabled']);
	}
}
