-include .env
export

BACKUP_KEEP ?= 5

.PHONY: test deploy backup

TEST_FILES := \
	test/song_search_test.rb \
	test/agent_test.rb \
	test/production_errors_test.rb \
	test/api_usage_test.rb \
	test/gpt_master_test.rb \
	test/cost_report_test.rb \
	test/e2e_telemetry_test.rb

test:
	@for f in $(TEST_FILES); do \
		echo ""; \
		echo "===== $$f ====="; \
		bundle exec ruby $$f || exit $$?; \
	done

deploy:
	ssh $(DEPLOY_HOST) 'cd ~/bot && git pull && docker compose up -d --build'

# Snapshot prod db/bot.db to db/bot.db.bak-<utc_timestamp> on the prod host and
# prune older backups, keeping the most recent BACKUP_KEEP (default 5).
# Override with: `make backup BACKUP_KEEP=10`.
backup:
	@ssh $(DEPLOY_HOST) 'cd ~/bot && \
		ts=$$(date -u +%Y%m%dT%H%M%SZ) && \
		cp db/bot.db db/bot.db.bak-$$ts && \
		echo "Created db/bot.db.bak-$$ts"; \
		ls -1t db/bot.db.bak-* 2>/dev/null | tail -n +$$(( $(BACKUP_KEEP) + 1 )) | xargs -r rm -f; \
		echo "Retained backups:"; \
		ls -lht db/bot.db.bak-* 2>/dev/null | head -n $(BACKUP_KEEP)'
