# Staff password reset with email OTP

The login screen now has **Reset password with email OTP**. Staff enter the email already registered on their Supabase Auth account, verify the email code, and choose a new password. Gmail addresses work through the normal Supabase email recovery service; no Gmail API or Google sign-in is needed. Normal password sign-in remains available. This does not register new accounts or change profile roles.

## Required Supabase dashboard setup

1. Open Authentication → Email Templates → Reset Password. Set the subject to `EZR password reset code`. Replace the body with the contents of `supabase/templates/reset-password-otp.html`. The `{{ .Token }}` placeholder is required: the default link-only template will not show a code for the app's OTP field.
2. Configure custom SMTP in Supabase Authentication to deliver to staff email addresses. Supabase's built-in test email service restricts recipients to project-team addresses. Keep SMTP credentials in the Supabase dashboard, never in browser code.
3. Verify every staff member has an existing Auth user with their real registered email and the corresponding `profiles` row. This reset flow never calls sign-up or creates a profile.
4. Review the project's email OTP expiry, email rate limits and password requirements in Authentication settings. The app defers code validity and password-policy enforcement to Supabase and displays its errors.
5. Test with an existing staff account: request a code, verify it, set and confirm a password, then sign in with the new password. Also check wrong/expired codes and repeated sends. A successful code verification alone does not open the EZR app.

The recovery client uses an in-memory session, separate from normal login storage. On completion or cancellation the recovery session is signed out. Reloading midway requires starting again. No service-role key, custom OTP table, SQL migration or plaintext password storage is used.

The code and template are prepared locally. Dashboard configuration and live email delivery have not been verified or changed by this implementation.

Official references:
- https://supabase.com/docs/reference/javascript/auth-resetpasswordforemail
- https://supabase.com/docs/reference/javascript/auth-verifyotp
- https://supabase.com/docs/guides/auth/auth-email-templates
- https://supabase.com/docs/guides/auth/auth-smtp
