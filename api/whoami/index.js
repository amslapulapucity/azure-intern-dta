/* Returns the caller's public IP address. Touches no database, so it costs
   nothing in serverless compute seconds. */
module.exports = async function (context, req) {
  const fwd = req.headers["x-forwarded-for"] || req.headers["x-azure-clientip"] || "";
  // x-forwarded-for is "client:port, proxy, proxy"; the first entry is the device
  let ip = String(fwd).split(",")[0].trim();
  if (ip.startsWith("[")) ip = ip.slice(1, ip.indexOf("]") >= 0 ? ip.indexOf("]") : undefined);
  else if (ip.lastIndexOf(":") > ip.indexOf(".") && ip.indexOf(".") > -1) ip = ip.slice(0, ip.lastIndexOf(":"));

  context.res = {
    headers: { "Content-Type": "application/json", "Cache-Control": "no-store" },
    body: { ip: ip || null }
  };
};
