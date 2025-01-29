deploy:
	cat config/settings.yml | grep deploy_to | sed 's/deploy_to:[ ]*\(.*\)/\1/g' | sed -e 's/["'\'']//g' | xargs -I srv \
	ssh srv 'source .zshrc && cd bot && git pull && bundle install --without development --path=.bundle && mkdir -p tmp && bin/bot restart'
