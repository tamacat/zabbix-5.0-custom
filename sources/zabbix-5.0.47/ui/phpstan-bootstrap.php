<?php declare(strict_types=1);
/**
 * PHPStan-only bootstrap. Deliberately does NOT call CAutoloader::register() (unlike
 * tests/bootstrap.php) — PHPStan's own scanDirectories setting provides full static class discovery,
 * and registering the runtime spl_autoload_register callback here makes PHPStan's BetterReflection
 * fall back to invoking it directly for any class it can't resolve statically, which fails because
 * CAutoloader::loadClass() is protected (a real incompatibility between PHPStan's reflection internals
 * and this hand-rolled autoloader, not something project code controls).
 */

define('ZBX_TESTS_ROOT_DIR', __DIR__);

if (!isset($_SERVER['REQUEST_URI'])) {
	$_SERVER['REQUEST_URI'] = '/zabbix.php';
}
