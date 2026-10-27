/// Fixed messages are safe to show across the service boundary. No callback
/// data or remote response bodies may be incorporated into these messages.
enum GranolaReturnFailure {
  noAttempt(
    'No Granola calendar sign-in is waiting. Start a new sign-in and keep its dialog open.',
  ),
  tooLong('The return link exceeds the supported length.'),
  wrongAddress(
    'Paste the Granola return link beginning https://www.granola.ai/app-redirect or granola://login-complete.',
  ),
  wrongState(
    'This return link belongs to a different Foresight sign-in attempt.',
  ),
  missingReturn('This return link does not contain a sign-in completion.'),
  malformed('The return link could not be parsed.'),
  missingCode(
    'The completion link must contain exactly one non-empty sign-in code.',
  ),
  unsupportedFlow(
    'This link finishes a Granola SSO or calendar-linking flow that this connection does not support yet.',
  ),
  wrongAttempt(
    'This completion link belongs to a different sign-in attempt. Use the new link from the current sign-in.',
  );

  const GranolaReturnFailure(this.message);
  final String message;
}
