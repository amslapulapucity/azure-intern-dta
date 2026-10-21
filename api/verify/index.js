const { getContainer, PK, toId } = require("../shared/cosmos");

/* Public certificate check. Deliberately open: a certificate is meant to be
   verifiable by whoever holds it. It answers with the completion facts only —
   no passwords, no time logs, no locations. */

const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
function checksum(body) {
  let h = 0;
  for (let i = 0; i < body.length; i++) h = (h * 31 + body.charCodeAt(i)) >>> 0;
  return ALPHABET.charAt(h % 32) + ALPHABET.charAt(Math.floor(h / 32) % 32);
}
function wellFormed(code) {
  if (!/^SSS-[A-Z0-9]{5}-[A-Z0-9]{2}$/.test(code)) return false;
  return checksum(code.slice(0, 9)) === code.slice(10);
}
const round = (x) => Math.round(x * 100) / 100;

module.exports = async function (context, req) {
  const headers = { "Content-Type": "application/json", "Cache-Control": "no-store" };
  const code = String(req.query.code || "").trim().toUpperCase();

  if (!wellFormed(code)) {
    context.res = { headers, body: { valid: false, reason: "That is not a valid certificate code." } };
    return;
  }

  try {
    const container = await getContainer();

    const { resources: dones } = await container.items
      .query({
        query: "SELECT TOP 1 c.key, c.doc FROM c WHERE c.pk = @pk AND c.deleted = false" +
               " AND STARTSWITH(c.key, 'done|') AND c.doc.code = @code",
        parameters: [{ name: "@pk", value: PK }, { name: "@code", value: code }]
      })
      .fetchAll();

    if (!dones.length) {
      context.res = { headers, body: { valid: false, reason: "No certificate matches that code." } };
      return;
    }

    const internId = dones[0].key.split("|")[1];
    const done = dones[0].doc || {};

    let intern = {}, settings = {};
    try {
      const r = await container.item(toId("user|" + internId), PK).read();
      if (r.resource && !r.resource.deleted) intern = r.resource.doc || {};
    } catch (e) { /* the intern record may have been removed */ }
    try {
      const r = await container.item(toId("settings"), PK).read();
      settings = (r.resource && r.resource.doc) || {};
    } catch (e) { /* settings not synced yet */ }

    if (!intern.name) {
      context.res = { headers, body: { valid: false, reason: "The intern for that code is no longer on file." } };
      return;
    }

    const office = intern.company && intern.company.trim()
      ? intern.company.trim()
      : [settings.company, settings.branch].filter(Boolean).join(", ");

    context.res = {
      headers,
      body: {
        valid: true,
        code: code,
        name: intern.name,
        company: office,
        requiredHours: intern.requiredHours === undefined || intern.requiredHours === null
          ? (settings.defaultRequired || null) : round(Number(intern.requiredHours)),
        renderedHours: done.minutes === undefined ? null : round(done.minutes / 60),
        date: done.date || null
      }
    };
  } catch (err) {
    context.log.error(err);
    context.res = { status: 500, headers, body: { valid: false, reason: "The verifier is unavailable right now." } };
  }
};
