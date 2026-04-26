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
	test/e2e_telemetry_test.rb \
	test/scratchpad_test.rb \
	test/chat_test.rb \
	test/agent_event_test.rb

test:
	@for f in $(TEST_FILES); do \
		echo ""; \
		echo "===== $$f ====="; \
		bundle exec ruby $$f || exit $$?; \
	done

deploy:
	ssh $(DEPLOY_HOST) 'cd ~/bot && git pull && docker compose up -d --build'

# Hot-snapshot prod db/bot.db and prune older backups, keeping the most recent
# BACKUP_KEEP (default 5). Override with: `make backup BACKUP_KEEP=10`.
# Backup logic lives in bin/backup.sh; this target just ships it over ssh.
backup:
	@ssh $(DEPLOY_HOST) bash -exs -- $(BACKUP_KEEP) < bin/backup.sh
