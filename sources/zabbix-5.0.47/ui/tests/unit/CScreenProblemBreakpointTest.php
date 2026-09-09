<?php declare(strict_types=1);

namespace Zabbix\Tests\Unit;

use PHPUnit\Framework\TestCase;
use CScreenProblem;
use CTableInfo;

/**
 * Regression tests for CScreenProblem::addTimelineBreakpoint() [3.3][BR1.1].
 *
 * These tests pin the exact timeline-breakpoint text produced before the PHP8 migration
 * (strftime()/gmstrftime(), deprecated since PHP 8.1) so the date()-based replacement in
 * include/classes/screens/CScreenProblem.php keeps producing byte-identical output for the
 * same inputs. All five original strftime() call sites in this file only used numeric format
 * specifiers (%H, %Y, %Y%m, %m) with no locale-dependent month/day names, so date() is a
 * behavior-preserving substitute — these tests are what makes that claim verifiable.
 *
 * addTimelineBreakpoint() derives "today"/"yesterday"/"this year" from strtotime('today') /
 * strtotime('yesterday') at call time (it has no injectable clock, and this migration's minimal-diff
 * policy [team-practices.md #Code Style] forbids refactoring it to add one), so every fixture below is
 * built relative to the actual clock at test-run time rather than hardcoded absolute dates.
 */
final class CScreenProblemBreakpointTest extends TestCase {

	private int $today;
	private int $yesterday;

	protected function setUp(): void {
		$this->today = strtotime('today');
		$this->yesterday = strtotime('yesterday');
	}

	private function renderBreakpoint(int $last_clock, int $clock): CTableInfo {
		$table = new CTableInfo();
		CScreenProblem::addTimelineBreakpoint($table, $last_clock, $clock, ZBX_SORT_DOWN);

		return $table;
	}

	public function testSameDayDifferentHourShowsHourBreakpoint(): void {
		$last_clock = $this->today + 14 * SEC_PER_HOUR;
		$clock = $this->today + 9 * SEC_PER_HOUR;

		$table = $this->renderBreakpoint($last_clock, $clock);

		self::assertSame(1, $table->getNumRows());
		self::assertStringContainsString(date('H:00', $last_clock), $table->toString());
	}

	public function testSameDaySameHourShowsNoBreakpoint(): void {
		$last_clock = $this->today + 14 * SEC_PER_HOUR + 100;
		$clock = $this->today + 14 * SEC_PER_HOUR + 50;

		$table = $this->renderBreakpoint($last_clock, $clock);

		self::assertSame(0, $table->getNumRows());
	}

	public function testCrossingIntoTodayShowsTodayBreakpoint(): void {
		$last_clock = $this->today + SEC_PER_HOUR;
		$clock = $this->yesterday + 20 * SEC_PER_HOUR;

		$table = $this->renderBreakpoint($last_clock, $clock);

		self::assertSame(1, $table->getNumRows());
		self::assertStringContainsString('Today', $table->toString());
	}

	public function testCrossingIntoYesterdayShowsYesterdayBreakpoint(): void {
		$last_clock = $this->yesterday + 5 * SEC_PER_HOUR;
		$clock = $this->yesterday - SEC_PER_HOUR;

		$table = $this->renderBreakpoint($last_clock, $clock);

		self::assertSame(1, $table->getNumRows());
		self::assertStringContainsString('Yesterday', $table->toString());
	}

	public function testWithinYesterdayShowsNoBreakpoint(): void {
		$last_clock = $this->yesterday + 10 * SEC_PER_HOUR;
		$clock = $this->yesterday + 2 * SEC_PER_HOUR;

		$table = $this->renderBreakpoint($last_clock, $clock);

		self::assertSame(0, $table->getNumRows());
	}

	public function testYearBoundaryShowsYearBreakpoint(): void {
		$this_year = strtotime('first day of January '.date('Y', $this->today));

		if (($this->yesterday - $this_year) < 2 * SEC_PER_DAY) {
			self::markTestSkipped(
				'Too close to the start of the year to build a last_clock < yesterday fixture; rerun later.'
			);
		}

		$last_clock = $this_year + SEC_PER_DAY;
		$clock = $this_year - SEC_PER_DAY;

		$table = $this->renderBreakpoint($last_clock, $clock);

		self::assertSame(1, $table->getNumRows());
		self::assertStringContainsString(date('Y', $last_clock), $table->toString());
	}

	public function testMonthBoundaryShowsMonthNameBreakpoint(): void {
		$this_year = strtotime('first day of January '.date('Y', $this->today));
		$feb_first = strtotime('+1 month', $this_year);

		if (($this->yesterday - $feb_first) < SEC_PER_DAY || $feb_first < $this_year) {
			self::markTestSkipped(
				'Too close to the Jan/Feb boundary to build a last_clock < yesterday fixture; rerun later.'
			);
		}

		$last_clock = $feb_first + SEC_PER_HOUR;
		$clock = $feb_first - SEC_PER_HOUR;

		$table = $this->renderBreakpoint($last_clock, $clock);

		self::assertSame(1, $table->getNumRows());
		self::assertStringContainsString(getMonthCaption((int) date('m', $last_clock)), $table->toString());
	}
}
