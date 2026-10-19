import '../core/errors.dart';

final RegExp _emailRegex = RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$');
final RegExp _phoneChars = RegExp(r'^[\d\s()+\-]+$');
final RegExp _nonDigit = RegExp(r'\D');

/// Throws unless [email] looks like an email address.
void validateEmail(String email) {
  if (!_emailRegex.hasMatch(email)) {
    fail('Invalid email: $email');
  }
}

/// A phone number as WhatsApp needs it: digits, optionally written with `+`,
/// spaces, dashes or brackets. The server normalises it and applies the
/// number's default country code to national numbers, so this only rejects
/// what can never work — an email address, or a digit count no real number
/// has.
void validatePhone(String phone) {
  if (phone.contains('@')) {
    fail('WhatsApp messages go to phone numbers, not email addresses: $phone');
  }
  if (!_phoneChars.hasMatch(phone)) {
    fail('Invalid phone number: $phone');
  }
  final int digits = phone.replaceAll(_nonDigit, '').length;
  if (digits < 7 || digits > 15) {
    fail('Invalid phone number: $phone');
  }
}

/// Unicode Cc other than tab, newline and carriage return
/// (`[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]`).
bool hasControlCharsExceptWhitespace(String s) {
  for (final int c in s.codeUnits) {
    if (c <= 0x08 || c == 0x0B || c == 0x0C || (c >= 0x0E && c <= 0x1F) || (c >= 0x7F && c <= 0x9F)) {
      return true;
    }
  }
  return false;
}

/// Any Unicode Cc (`[\u0000-\u001F\u007F-\u009F]`).
bool hasControlChars(String s) {
  for (final int c in s.codeUnits) {
    if (c <= 0x1F || (c >= 0x7F && c <= 0x9F)) return true;
  }
  return false;
}

/// Characters as a person counts them (code points, like JavaScript's
/// `Array.from(s).length`).
int codePointLength(String s) => s.runes.length;
