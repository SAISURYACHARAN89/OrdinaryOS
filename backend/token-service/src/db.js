/**
 * One MongoDB connection for the life of the process, shared by every
 * request. On Lambda the process outlives a single request, so the client is
 * created once and reused rather than reconnecting each time.
 *
 * Two databases on the same cluster: the store's (read only — customers and
 * orders) and Ordinary's own (accounts, devices, usage).
 */
import { MongoClient } from 'mongodb';

let connecting = null;

export function databases() {
  const uri = process.env.MONGODB_URI;
  if (!uri) return null;
  connecting ??= new MongoClient(uri, {
    maxPoolSize: 5,
    serverSelectionTimeoutMS: 6000,
  })
    .connect()
    .then((client) => ({
      client,
      store: client.db(process.env.STORE_DB ?? 'test'),
      ordinary: client.db(process.env.ORDINARY_DB ?? 'ordinary'),
    }))
    .catch((error) => {
      // Let the next request try again instead of caching the failure.
      connecting = null;
      throw error;
    });
  return connecting;
}
