---
paths:
  - "lib/knowledge_base.rb"
  - "lib/embedding_service.rb"
  - "models/knowledge.rb"
  - "models/knowledge_compact_log.rb"
  - "lib/commands/knowledge_*.rb"
  - "lib/task_handlers/knowledge_compact_handler.rb"
  - "lib/agent/tools/knowledge.rb"
---

# Knowledge base / embeddings gotchas

Reference: `docs/architecture.md` § KnowledgeBase / § EmbeddingService.

- Knowledge auto-extraction runs in a background Thread every `knowledge.extract_every` messages per chat
- Embeddings deduplication threshold is 0.92 cosine similarity — near-duplicate facts are not stored
- Knowledge auto-compaction (`KnowledgeBase.compact!`) clusters near-dupes via stored embeddings (no API calls) and LLM-merges each cluster; triggered as a `knowledge_compact` background task when count >= adaptive threshold (`compact_at` × factor based on last run's avg cluster size); logs to `log/knowledge_compact.log`; history in `knowledge_compact_log` table
- `бот сожми знания` (admin only) triggers compaction immediately for the current chat
