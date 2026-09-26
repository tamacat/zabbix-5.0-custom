<?php declare(strict_types=1);

namespace Zabbix\Tests\Integration;

use PHPUnit\Framework\TestCase;

/**
 * DBconnect(), DBselect() and DBexecute() (and everything built on them) were written for PHP < 8.1, where a
 * failed mysqli call returns false and leaves an error string behind. PHP 8.1+ throws mysqli_sql_exception
 * instead, so without the try/catch in MysqlDbBackend::connect() and db.inc.php a failed connect or query
 * escapes as an uncaught exception rather than reaching the frontend's own error handling.
 *
 * The connect test needs no database (it points at a port nothing listens on) and always runs. The query test
 * needs a reachable test MySQL (ZBX_TEST_DB_*) and skips itself otherwise, like AuthenticationConfigTest.
 */
final class DbErrorHandlingTest extends TestCase {

	/** @var array<string, mixed> */
	private array $db_backup = [];

	// $ZBX_MESSAGES is read and reset directly: clear_messages() runs the messages through filter_messages(),
	// which depends on whatever CWebUser::$data an earlier test in the same process left behind.
	protected function setUp(): void {
		global $DB, $ZBX_MESSAGES;

		$this->db_backup = $DB;
		$ZBX_MESSAGES = [];
	}

	protected function tearDown(): void {
		global $DB, $ZBX_MESSAGES;

		if (isset($DB['DB']) && $DB['DB'] !== null) {
			\DBclose();
		}

		$DB = $this->db_backup;
		$ZBX_MESSAGES = [];
	}

	public function testConnectToUnreachableServerReturnsFalseWithMessage(): void {
		global $DB;

		unset($DB['DB']);
		$DB['SERVER'] = '127.0.0.1';
		$DB['PORT'] = 1;

		$error = null;
		$connected = \DBconnect($error);

		$this->assertFalse($connected);
		$this->assertIsString($error);
		$this->assertNotSame('', $error);
	}

	public function testFailedQueriesReturnFalseAndRecordAnError(): void {
		global $ZBX_MESSAGES;

		$error = null;

		if (!\DBconnect($error)) {
			$this->markTestSkipped(
				'No reachable test MySQL database (ZBX_TEST_DB_HOST/.../ZBX_TEST_DB_DATABASE): '.(string) $error
			);
		}

		$this->assertFalse(\DBselect('SELECT * FROM zbx_table_that_does_not_exist'));
		$this->assertFalse(\DBexecute('UPDATE zbx_table_that_does_not_exist SET x = 1'));

		$this->assertCount(2, $ZBX_MESSAGES);
		foreach ($ZBX_MESSAGES as $message) {
			$this->assertSame('sql', $message['src']);
			$this->assertStringContainsString('zbx_table_that_does_not_exist', $message['message']);
		}
	}
}
