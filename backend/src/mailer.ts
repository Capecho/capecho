// Transactional email delivery for the email sign-in code (M3). Kept behind a tiny Mailer
// interface so the OTP route is testable with a fake, the dev loop runs without a vendor, and the
// real path (Resend) is a single swap. The mailer ONLY ever sends the sign-in code — there is no
// other templated mail — so the surface is deliberately one method.
//
// Fail-closed posture: production with no RESEND_API_KEY returns null from selectMailer ⇒ the route
// answers 503 (email sign-in unconfigured) rather than silently dropping codes.

export interface Mailer {
  /** Deliver a sign-in code to `to`. Throws on a delivery failure so the route can clear the
   *  pending code and let the user retry (rather than stranding an undelivered code). */
  sendLoginCode(to: string, code: string): Promise<void>;
}

/** Thrown on a non-2xx from the mail vendor. The message carries only a non-PII status tag — never
 *  the vendor body (which can echo the recipient address). */
export class MailerError extends Error {}

/** A reasonable default sender; override with EMAIL_FROM once the sending domain is verified in
 *  Resend. MUST be on a domain you've verified, or Resend rejects the send. */
export const DEFAULT_EMAIL_FROM = "Capecho <login@capecho.com>";

const RESEND_ENDPOINT = "https://api.resend.com/emails";

/**
 * Resend (https://resend.com) transactional sender. One POST per code. A non-2xx throws a
 * `MailerError` with only the status code, so the route surfaces a generic send failure and logs no
 * recipient PII. The API key is a Worker Secret and is never logged.
 */
export function resendMailer(apiKey: string, from: string = DEFAULT_EMAIL_FROM): Mailer {
  return {
    async sendLoginCode(to: string, code: string): Promise<void> {
      const res = await fetch(RESEND_ENDPOINT, {
        method: "POST",
        headers: {
          authorization: `Bearer ${apiKey}`,
          "content-type": "application/json",
        },
        body: JSON.stringify({
          from,
          to: [to],
          subject: `${code} is your Capecho sign-in code`,
          text: loginCodeText(code),
          html: loginCodeHtml(code),
        }),
      });
      if (!res.ok) {
        // Drain the body so the socket can be reused, but never include it in the thrown error.
        await res.text().catch(() => "");
        throw new MailerError(`resend_http_${res.status}`);
      }
    },
  };
}

/**
 * Dev-only mailer: never sends, logs the code to the Worker console so a local run can complete the
 * flow without a Resend key. Selected ONLY when DEV_TRUST_MOCK_AUTH is on AND no RESEND_API_KEY is
 * set (see selectMailer) — it must never be reachable in production.
 */
export function devLogMailer(): Mailer {
  return {
    async sendLoginCode(to: string, code: string): Promise<void> {
      console.log("dev_email_code", { to, code });
    },
  };
}

/** The env fields selectMailer reads (a subset of Env, kept local to avoid a circular import). */
export interface MailerEnv {
  RESEND_API_KEY?: string;
  EMAIL_FROM?: string;
  DEV_TRUST_MOCK_AUTH?: string;
}

/**
 * Pick the mailer for this environment:
 *  - a real Resend sender when RESEND_API_KEY is set (production / staging);
 *  - else a dev log mailer when DEV_TRUST_MOCK_AUTH is on (local dev without a vendor);
 *  - else null ⇒ email sign-in is unconfigured and the route FAILS CLOSED (503).
 */
export function selectMailer(env: MailerEnv): Mailer | null {
  if (env.RESEND_API_KEY) return resendMailer(env.RESEND_API_KEY, env.EMAIL_FROM || DEFAULT_EMAIL_FROM);
  if (env.DEV_TRUST_MOCK_AUTH === "true") return devLogMailer();
  return null;
}

// --- templates ---------------------------------------------------------------
// Plain, vendor-neutral, inline-styled (email clients strip <style>/<head>). The code is the only
// dynamic value and is a 6-digit string, so no escaping is required.

function loginCodeText(code: string): string {
  return [
    `Your Capecho sign-in code is ${code}`,
    ``,
    `Enter this code in Capecho to finish signing in. It expires in 10 minutes.`,
    `If you didn't request it, you can safely ignore this email — no one can sign in without the code.`,
  ].join("\n");
}

function loginCodeHtml(code: string): string {
  return `<!doctype html>
<html>
  <body style="margin:0;padding:0;background:#f3f0ea;">
    <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f0ea;padding:32px 0;">
      <tr><td align="center">
        <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:440px;background:#fbfaf7;border:1px solid #e0d9cf;border-radius:14px;">
          <tr><td style="padding:32px 36px 8px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;">
            <div style="font-size:20px;font-weight:600;color:#2b2320;letter-spacing:-0.01em;">Capecho<span style="color:#a8741e;">.</span></div>
          </td></tr>
          <tr><td style="padding:8px 36px 0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;font-size:15px;line-height:1.55;color:#5a4a40;">
            Here's your sign-in code. Enter it in Capecho to finish signing in.
          </td></tr>
          <tr><td style="padding:22px 36px;">
            <div style="font-family:'SFMono-Regular',ui-monospace,Menlo,Consolas,monospace;font-size:34px;font-weight:600;letter-spacing:0.32em;color:#2b2320;background:#efeae3;border:1px solid #e0d9cf;border-radius:10px;padding:16px 0;text-align:center;">${code}</div>
          </td></tr>
          <tr><td style="padding:0 36px 30px;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Helvetica,Arial,sans-serif;font-size:13px;line-height:1.55;color:#8a7d72;">
            This code expires in 10 minutes. If you didn't request it, you can safely ignore this email — no one can sign in without it.
          </td></tr>
        </table>
      </td></tr>
    </table>
  </body>
</html>`;
}
