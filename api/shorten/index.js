/* Turns a certificate link into a bit.ly link, using the certificate code as
   the custom back-half when the Bitly account allows it.

   The Bitly token lives in the BITLY_TOKEN application setting and never
   reaches the browser. Without that setting the endpoint answers
   "not configured" and the app keeps using its own short /v/ links. */

const API = "https://api-ssl.bitly.com/v4";

async function bitly(path, method, token, body) {
  const r = await fetch(API + path, {
    method,
    headers: { Authorization: "Bearer " + token, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined
  });
  const data = await r.json().catch(() => ({}));
  return { status: r.status, data };
}

function why(status, data) {
  if (status === 403) return "Bitly rejected the token";
  if (status === 402) return "custom back-half needs a paid Bitly plan";
  if (status === 429) return "Bitly monthly link limit reached";
  return data.description || data.message || "Bitly returned " + status;
}

module.exports = async function (context, req) {
  const headers = { "Content-Type": "application/json", "Cache-Control": "no-store" };

  if (process.env.SYNC_KEY && (req.headers["x-app-key"] || "") !== process.env.SYNC_KEY) {
    context.res = { status: 401, headers, body: { link: null, reason: "Unauthorized" } };
    return;
  }

  const token = process.env.BITLY_TOKEN;
  if (!token) {
    context.res = { headers, body: { link: null, reason: "BITLY_TOKEN is not set" } };
    return;
  }

  const url = String((req.body && req.body.url) || "");
  const backhalf = String((req.body && req.body.backhalf) || "").trim();
  const domain = process.env.BITLY_DOMAIN || "bit.ly";

  if (!/^https:\/\/[^\s]+$/i.test(url)) {
    context.res = { status: 400, headers, body: { link: null, reason: "A https link is required" } };
    return;
  }
  if (backhalf && !/^[A-Za-z0-9_-]{4,20}$/.test(backhalf)) {
    context.res = { status: 400, headers, body: { link: null, reason: "Invalid back-half" } };
    return;
  }

  try {
    // 1. the plain short link (200 when Bitly already had this long url, 201 when new)
    const made = await bitly("/shorten", "POST", token, { long_url: url, domain });
    if (!(made.status === 200 || made.status === 201) || !made.data.link) {
      const reason = why(made.status, made.data);
      context.log.warn("bitly shorten: " + reason);
      context.res = { headers, body: { link: null, reason } };
      return;
    }
    const plain = made.data.link;

    if (!backhalf) {
      context.res = { headers, body: { link: plain, custom: false } };
      return;
    }

    // 2. rename its back-half to the certificate code
    const want = domain + "/" + backhalf;
    const custom = await bitly("/custom_bitlinks", "POST", token, {
      custom_bitlink: want,
      bitlink_id: made.data.id
    });
    if (custom.status === 200 || custom.status === 201) {
      context.res = { headers, body: { link: "https://" + want, custom: true } };
      return;
    }

    // 3. already taken? if it is ours and points at the same place, use it anyway
    const existing = await bitly("/bitlinks/" + encodeURIComponent(want), "GET", token);
    if (existing.status === 200 && existing.data.long_url === url) {
      context.res = { headers, body: { link: "https://" + want, custom: true } };
      return;
    }

    const reason = why(custom.status, custom.data);
    context.log.warn("bitly custom back-half: " + reason);
    context.res = { headers, body: { link: plain, custom: false, reason: reason } };
  } catch (err) {
    context.log.error(err);
    context.res = { headers, body: { link: null, reason: "Could not reach Bitly" } };
  }
};
