// Web build: DPAPI does not exist there (TokenStore only calls these on Windows).
String? protect(String plain) => null;
String? unprotect(String sealed) => null;
