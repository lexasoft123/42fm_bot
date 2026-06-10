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
	test/agent_event_test.rb \
	test/cron_scheduler_test.rb \
	test/suno_handler_chain_test.rb \
	test/suno_client_test.rb \
	test/attached_audio_test.rb \
	test/telegram_file_test.rb \
	test/suno_cover_art_handler_test.rb \
	test/cover_art_tool_test.rb \
	test/admin_menu_test.rb \
	test/bot_dispatcher_test.rb \
	test/rate_limiter_test.rb \
	test/model_provider_client_test.rb \
	test/image_gen_adapter_test.rb \
	test/knowledge_base_test.rb \
	test/chat_context_serialize_test.rb \
	test/convert_to_wav_tool_test.rb \
	test/cover_audio_tool_test.rb \
	test/suno_language_policy_test.rb \
	test/compose_song_tool_test.rb \
	test/suno_wav_convert_handler_test.rb \
	test/gogolmogol_test.rb \
	test/google_search_tool_test.rb \
	test/radio_degradation_test.rb \
	test/view_image_test.rb

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
