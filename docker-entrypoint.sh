#!/bin/sh
set -e

echo "Waiting for Ollama..."
for i in $(seq 1 30); do
  if curl -sf http://localhost:11434/api/tags > /dev/null 2>&1; then
    echo "Ollama is ready"
    break
  fi
  [ "$i" -eq 30 ] && echo "WARN: Ollama not reachable, continuing anyway"
  sleep 2
done

OLLAMA_MODEL="${OLLAMA_MODEL:-huihui_ai/qwen3.5-abliterated:9b}"
echo "Ensuring model ${OLLAMA_MODEL} is available..."
curl -sf http://localhost:11434/api/show -d "{\"name\":\"${OLLAMA_MODEL}\"}" > /dev/null 2>&1 || \
  curl -f http://localhost:11434/api/pull -d "{\"name\":\"${OLLAMA_MODEL}\"}" || \
  echo "WARN: Failed to pull model, will retry at runtime"

echo "Running DB migrations..."
bundle exec rake db:migrate
echo "Starting bot..."
exec "$@"
