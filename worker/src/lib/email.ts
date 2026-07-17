import type { WorkerEnv } from "../env.ts";

export async function sendEmail(
  env: WorkerEnv,
  to: string,
  subject: string,
  text: string,
  template: "recovery" | "trial_reminder",
): Promise<boolean> {
  try {
    await env.EMAIL.send({
      to,
      from: { email: env.EMAIL_FROM, name: "llmpilot" },
      replyTo: "support@llmpilot.dev",
      subject,
      text,
      html: `<pre style="font:inherit;white-space:pre-wrap">${text.replace(/[&<>]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;" })[c]!)}</pre>`,
    });
    return true;
  } catch (error) {
    const code = typeof error === "object" && error !== null && "code" in error ? String(error.code) : "unknown";
    console.error(JSON.stringify({ event: "email_failed", template, code }));
    return false;
  }
}
