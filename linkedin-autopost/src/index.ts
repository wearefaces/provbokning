import { config, configWarnings } from "./config.js";
import "./db.js"; // initialize schema on boot
import { buildServer } from "./server.js";
import { startScheduler } from "./scheduler.js";
import { logger } from "./logger.js";

function main(): void {
  for (const w of configWarnings()) logger.warn(w);

  const app = buildServer();
  app.listen(config.port, () => {
    logger.info(`linkedin-autopost listening on ${config.baseUrl} (port ${config.port})`);
    if (!config.appPassword) {
      logger.warn("APP_PASSWORD not set — the UI is OPEN. Set one before exposing this publicly.");
    }
  });

  startScheduler();
}

main();
