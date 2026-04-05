#!/bin/sh
set -e
echo "Running DB migrations..."
bundle exec rake db:migrate
echo "Starting bot..."
exec "$@"
