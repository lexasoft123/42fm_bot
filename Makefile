-include .env
export

.PHONY: test deploy

test:
	bundle exec ruby test/song_search_test.rb

deploy:
	ssh $(DEPLOY_HOST) 'cd ~/bot && git pull && docker compose up -d --build'
