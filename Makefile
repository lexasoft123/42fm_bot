-include .env
export

.PHONY: test deploy

test:
	bundle exec ruby test/song_search_test.rb

deploy:
	ssh $(DEPLOY_HOST) 'cd ~/bot && git pull && docker compose up -d --build'

ollama-pull:
	curl -f http://localhost:11434/api/pull -d '{"name":"$(OLLAMA_MODEL)"}'
