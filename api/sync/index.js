const { getContainer, PK, toId } = require("../shared/cosmos");

/* The browser speaks in records: { key, doc, deleted }, where key is one of
     settings
     user|<internId>
     log|<internId>|<YYYY-MM-DD>
     login|<internId>|<ISO timestamp>
     done|<internId>
   Each one is a document here, stamped with the server time so a device can
   ask "what changed since I last looked". */

module.exports = async function (context, req) {
  if (process.env.SYNC_KEY && (req.headers["x-app-key"] || "") !== process.env.SYNC_KEY) {
    context.res = { status: 401, body: { error: "Unauthorized" } };
    return;
  }

  try {
    const container = await getContainer();
    const now = Date.now();
    const body = (req.method === "POST" && req.body) || {};
    const since = Number(body.since !== undefined ? body.since : req.query.since || 0) || 0;
    const items = Array.isArray(body.items) ? body.items : [];

    // writes first, all carrying the same server timestamp
    for (const it of items) {
      if (!it || !it.key) continue;
      await container.items.upsert({
        id: toId(it.key),
        pk: PK,
        key: it.key,
        t: now,
        deleted: !!it.deleted,
        doc: it.deleted ? null : (it.doc || null)
      });
    }

    // then everything newer than the caller's last sync
    const { resources } = await container.items
      .query({
        query: "SELECT c.key, c.t, c.deleted, c.doc FROM c WHERE c.pk = @pk AND c.t > @since",
        parameters: [{ name: "@pk", value: PK }, { name: "@since", value: since }]
      })
      .fetchAll();

    context.res = {
      headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
      body: { now, items: resources }
    };
  } catch (err) {
    context.log.error(err);
    context.res = { status: 500, body: { error: String((err && err.message) || err) } };
  }
};
