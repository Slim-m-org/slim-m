-- How much of its fuel budget each command's runs have used, so an admin can see which module is
-- heavy before it hits the limit: the last run's, and the most any run has used. The last one is
-- absent for a run whose fuel could not be read (it timed out).
ALTER TABLE module_run_stats ADD COLUMN last_fuel_used INTEGER;
ALTER TABLE module_run_stats ADD COLUMN max_fuel_used INTEGER NOT NULL DEFAULT 0;
