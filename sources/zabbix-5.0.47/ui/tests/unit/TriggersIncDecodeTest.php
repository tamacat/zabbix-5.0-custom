<?php declare(strict_types=1);

namespace Zabbix\Tests\Unit;

use PHPUnit\Framework\TestCase;

/**
 * Regression tests for utf8RawUrlDecode() [3.4][BR1.1] in include/triggers.inc.php.
 *
 * utf8_encode() (ISO-8859-1 -> UTF-8) was deprecated in PHP 8.2. The removed call site passed it
 * $entity = "&#".$unicode.';' — a string built only from the decimal digits produced by hexdec() plus the
 * literal "&#"/";" characters, i.e. always pure 7-bit ASCII. utf8_encode() is the identity transform on
 * ASCII input, so html_entity_decode($entity, ...) alone (without the removed utf8_encode() wrapper)
 * decodes to byte-identical output for every codepoint, not just the Latin-1 range the old ISO-8859-1
 * source encoding nominally covered. These tests pin that equivalence.
 */
final class TriggersIncDecodeTest extends TestCase {

	public function testPlainAsciiStringIsUnchanged(): void {
		self::assertSame('no special characters here', utf8RawUrlDecode('no special characters here'));
	}

	public function testUnicodeEscapeInLatin1RangeIsDecoded(): void {
		// %u00e9 -> U+00E9 LATIN SMALL LETTER E WITH ACUTE ("e" with an accent).
		self::assertSame("\u{00E9}", utf8RawUrlDecode('%u00e9'));
	}

	public function testUnicodeEscapeOutsideLatin1RangeIsDecoded(): void {
		// %u3042 -> U+3042 HIRAGANA LETTER A. Outside the ISO-8859-1 range the removed utf8_encode() call
		// nominally targeted, proving its removal never depended on the codepoint being in that range.
		self::assertSame("\u{3042}", utf8RawUrlDecode('%u3042'));
	}

	public function testUnicodeEscapeForAsciiCodepointDecodesToPlainCharacter(): void {
		// %u0041 -> U+0041 'A'.
		self::assertSame('A', utf8RawUrlDecode('%u0041'));
	}

	public function testPercentNotFollowedByUIsPassedThroughUnchanged(): void {
		// Only the legacy JS escape()-style "%uXXXX" form is decoded; a plain percent escape is untouched.
		self::assertSame('100%41 done', utf8RawUrlDecode('100%41 done'));
	}

	public function testMixedTextWithEmbeddedUnicodeEscapeDecodesCorrectly(): void {
		self::assertSame("caf\u{00E9} au lait", utf8RawUrlDecode('caf%u00e9 au lait'));
	}
}
