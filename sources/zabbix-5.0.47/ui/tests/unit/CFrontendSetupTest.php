<?php declare(strict_types=1);

namespace Zabbix\Tests\Unit;

use PHPUnit\Framework\TestCase;
use CFrontendSetup;

/**
 * Regression tests for CFrontendSetup [3.5][3.6][FR1.4][FR3.3].
 *
 * Covers:
 *  - MIN_PHP_VERSION raised from '7.2.0' to '8.0.0' and checkPhpVersion() reading it correctly [3.5].
 *  - checkPhpLdapModule() and its checkRequirements() call site were deleted along with the LDAP feature
 *    [3.1][3.6][FR2.1] — the PHP "ldap" extension is intentionally no longer part of the requirements list
 *    or the web image's PHP extension set (docker/web/Dockerfile).
 *  - checkPhpOpenSsl() was deliberately kept (it is a general requirement independent of the removed SAML
 *    feature — see code-generation-plan.md Step 3.2) and still runs as part of checkRequirements().
 */
final class CFrontendSetupTest extends TestCase {

	private CFrontendSetup $setup;

	protected function setUp(): void {
		$this->setup = new CFrontendSetup();
	}

	public function testMinPhpVersionConstantIsRaisedToPhp8(): void {
		self::assertSame('8.0.0', CFrontendSetup::MIN_PHP_VERSION);
	}

	public function testCheckPhpVersionReportsTheNewMinimumVersion(): void {
		$check = $this->setup->checkPhpVersion();

		self::assertSame('8.0.0', $check['required']);
		self::assertStringContainsString('8.0.0', $check['error']);
	}

	public function testCheckPhpVersionPassesUnderThePhp8RuntimeTheseTestsRunOn(): void {
		// This test suite itself only runs under PHP8.x (composer.json requires php >=8.0), so the check
		// against the new 8.0.0 floor must report CHECK_OK for the interpreter actually running it.
		$check = $this->setup->checkPhpVersion();

		self::assertSame(CFrontendSetup::CHECK_OK, $check['result']);
	}

	public function testCheckPhpLdapModuleMethodWasRemoved(): void {
		self::assertFalse(
			method_exists(CFrontendSetup::class, 'checkPhpLdapModule'),
			'checkPhpLdapModule() must stay removed along with CLdap/CLdapAuthValidator [FR2.1][BR2.2].'
		);
	}

	public function testCheckPhpOpenSslMethodWasKept(): void {
		self::assertTrue(
			method_exists(CFrontendSetup::class, 'checkPhpOpenSsl'),
			'checkPhpOpenSsl() must be kept — it is a general requirement, unrelated to the removed SAML feature.'
		);
	}

	public function testCheckRequirementsNoLongerReportsAnLdapCheck(): void {
		$names = array_column($this->setup->checkRequirements(), 'name');

		self::assertNotContains('PHP LDAP', $names);
	}

	public function testCheckRequirementsStillReportsAnOpenSslCheck(): void {
		$names = array_column($this->setup->checkRequirements(), 'name');

		self::assertContains('PHP OpenSSL', $names);
	}

	public function testCheckRequirementsReturnsWellFormedEntries(): void {
		$results = $this->setup->checkRequirements();

		self::assertNotEmpty($results);

		foreach ($results as $check) {
			self::assertIsArray($check);
			foreach (['name', 'current', 'required', 'result', 'error'] as $key) {
				self::assertArrayHasKey($key, $check);
			}
			self::assertContains($check['result'], [
				CFrontendSetup::CHECK_OK, CFrontendSetup::CHECK_WARNING, CFrontendSetup::CHECK_FATAL
			]);
		}
	}
}
