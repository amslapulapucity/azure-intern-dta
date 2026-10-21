const { CosmosClient } = require("@azure/cosmos");

const DB = process.env.COSMOS_DB || "interndta";
const CONTAINER = process.env.COSMOS_CONTAINER || "records";
const PK = "app";                       // one logical partition is plenty here

let containerPromise = null;

function getContainer() {
  if (!process.env.COSMOS_CONN) {
    return Promise.reject(new Error("COSMOS_CONN application setting is missing"));
  }
  if (!containerPromise) {
    const client = new CosmosClient(process.env.COSMOS_CONN);
    containerPromise = (async () => {
      const { database } = await client.databases.createIfNotExists({ id: DB });
      const { container } = await database.containers.createIfNotExists(
        { id: CONTAINER, partitionKey: { paths: ["/pk"] } },
        { offerThroughput: 400 }        // inside the 1000 RU/s free allowance
      );
      return container;
    })().catch((e) => {
      containerPromise = null;
      throw e;
    });
  }
  return containerPromise;
}

// Cosmos ids cannot contain / \ # ? so the record key is encoded
const toId = (key) => encodeURIComponent(key);

module.exports = { getContainer, PK, toId };
