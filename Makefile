-include .env
export

.PHONY: test deploy

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
