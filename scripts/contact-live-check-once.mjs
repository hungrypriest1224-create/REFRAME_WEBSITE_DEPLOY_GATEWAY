const endpoint = "https://reframe-web.org/api/contact";
const form = new URLSearchParams({
  inquiry_type: "rebuild",
  name: "RE:FRAME Live Check",
  email: "reframe-live-check@example.com",
  website: "https://reframe-web.org/",
  timing: "consult",
  budget: "consult",
  message: "RE:FRAME contact form end-to-end delivery check.",
  privacy_agreed: "yes",
});
const response = await fetch(endpoint, {
  method: "POST",
  headers: {
    Origin: "https://reframe-web.org",
    Accept: "application/json",
    "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
  },
  body: form,
  signal: AbortSignal.timeout(20000),
});
const payload = await response.json().catch(() => ({}));
if (response.status !== 200 || payload.success !== true) {
  throw new Error(`Live contact check failed with HTTP ${response.status}.`);
}
console.log("Live contact form handoff succeeded.");
