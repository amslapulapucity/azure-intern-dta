const { getContainer, PK } = require("../shared/cosmos");

module.exports = async function (context, req) {
  const out = { ok: true, time: new Date().toISOString(), api: "intern-dta", store: "cosmos" };
  if (req.query.db === "1") {
    try {
      const container = await getContainer();
      const { resources } = await container.items
        .query({
          query: "SELECT VALUE COUNT(1) FROM c WHERE c.pk = @pk AND STARTSWITH(c.key, 'user|')",
          parameters: [{ name: "@pk", value: PK }]
        })
        .fetchAll();
      out.db = "connected";
      out.accounts = resources[0] || 0;
    } catch (e) {
      out.ok = false;
      out.db = "error: " + ((e && e.message) || e);
      context.res = { status: 500, headers: { "Cache-Control": "no-store" }, body: out };
      return;
    }
  }
  context.res = { headers: { "Cache-Control": "no-store" }, body: out };
};
