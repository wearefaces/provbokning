import cron from "node-cron";
import { config } from "./config.js";
import { runPipeline } from "./pipeline.js";
import { logger } from "./logger.js";

let task: cron.ScheduledTask | null = null;

export function startScheduler(): void {
  if (!cron.validate(config.generateCron)) {
    logger.error(`Invalid GENERATE_CRON "${config.generateCron}" — scheduler not started.`);
    return;
  }
  task = cron.schedule(config.generateCron, async () => {
    logger.info("Scheduled generation run triggered");
    try {
      await runPipeline();
    } catch (err) {
      logger.error("Scheduled run failed", err);
    }
  });
  logger.info(`Scheduler started (cron: "${config.generateCron}")`);
}

export function stopScheduler(): void {
  task?.stop();
  task = null;
}
