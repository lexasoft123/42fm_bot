require 'set'

module AdminMenu
  module Views
    PAGE_SIZE = 5

    module_function

    def root
      kb = inline([
        [btn('📋 Чаты',     'adm:chats:0')],
        [btn('👥 Админы',   'adm:admins:0')],
        [btn('📊 Статус',   'adm:status')],
        [btn('❌ Закрыть',  'adm:close')],
      ])
      { text: "Админ-меню\n\nВыбери раздел:", reply_markup: kb }
    end

    def chats(page: 0, api: nil)
      total = Chat.count
      pages = [(total + PAGE_SIZE - 1) / PAGE_SIZE, 1].max
      page  = page.clamp(0, pages - 1)
      # Live chats first: authorized DESC, then most recently seen (SQLite
      # sorts NULL last_seen_at last under DESC) — dead legacy rows sink to
      # the tail pages instead of burying the real chats.
      rows = Chat.order(Arel.sql('authorized DESC, last_seen_at DESC, chat_id'))
                 .offset(page * PAGE_SIZE).limit(PAGE_SIZE).to_a
      refresh_titles!(rows, api) if api

      buttons = rows.map { |c|
        flag  = c.authorized ? '✓' : '✗'
        audio = c.audio      ? ' 🎵' : ''
        [btn("#{flag} #{display_title(c)}#{audio}", "adm:chat:#{c.chat_id}")]
      }

      nav = []
      nav << btn('⏪', "adm:chats:#{page - 1}") if page > 0
      nav << btn('⏩', "adm:chats:#{page + 1}") if page < pages - 1
      buttons << nav unless nav.empty?
      buttons << [btn('⬅️ Назад', 'adm:root')]

      text = "Чаты (стр. #{page + 1}/#{pages}, всего #{total})"
      { text: text, reply_markup: inline(buttons) }
    end

    def chat_detail(chat_id:, api: nil)
      chat = Chat.find_by(chat_id: chat_id)
      return { text: "Чат #{chat_id} не найден", reply_markup: inline([[btn('⬅️ Назад', 'adm:chats:0')]]) } unless chat

      auth_label  = chat.authorized ? '🔒 Деавторизовать' : '🔓 Авторизовать'
      audio_label = chat.audio      ? '🎵 Аудио: вкл'      : '🎵 Аудио: выкл'

      buttons = []
      open_btn = chat_open_button(chat, api)
      buttons << [open_btn] if open_btn
      buttons.concat([
        [btn(auth_label,   "adm:chat_toggle_auth:#{chat_id}")],
        [btn(audio_label,  "adm:chat_toggle_audio:#{chat_id}")],
        [btn('⚙️ Лимиты',  "adm:chat_limits:#{chat_id}")],
        [btn('⬅️ Назад',   'adm:chats:0')],
      ])

      lines = [
        unknown_title?(chat.title) ? "id: #{chat.chat_id}" : "#{chat.title} (id: #{chat.chat_id})",
        "type: #{chat.chat_type}",
        "authorized: #{chat.authorized ? '✓' : '✗'}",
        "audio: #{chat.audio ? '✓' : '✗'}",
        "rate_limits: #{chat.rate_limits.to_s.empty? ? '(default)' : chat.rate_limits}",
      ]
      { text: lines.join("\n"), reply_markup: inline(buttons) }
    end

    def chat_limits(chat_id:)
      chat = Chat.find_by(chat_id: chat_id)
      return { text: "Чат #{chat_id} не найден", reply_markup: inline([[btn('⬅️ Назад', 'adm:chats:0')]]) } unless chat

      current = (JSON.parse(chat.rate_limits.to_s) rescue {}) || {}
      buckets = %w[image suno]
      rows = buckets.map { |b|
        v = current[b] || Settings.auth.dig('rate_limits', b) || {}
        max = v['max'] || '?'
        win = v['window_minutes'] || '?'
        [btn("#{b}: max=#{max}, окно=#{win}мин", "adm:chat_limit_edit:#{chat_id}:#{b}")]
      }
      rows << [btn('⬅️ Назад', "adm:chat:#{chat_id}")]

      text = "Лимиты для «#{display_title(chat)}»\n\nНажми бакет, чтобы изменить."
      { text: text, reply_markup: inline(rows) }
    end

    def admins(page: 0)
      admin_users   = User.where(role: 'admin').order(:uid).to_a
      member_users  = User.where.not(role: 'admin').order(last_order: :desc).limit(20).to_a
      all = admin_users + member_users
      pages = [(all.size + PAGE_SIZE - 1) / PAGE_SIZE, 1].max
      page  = page.clamp(0, pages - 1)
      rows  = all.slice(page * PAGE_SIZE, PAGE_SIZE) || []

      buttons = rows.map { |u|
        flag = u.role == 'admin' ? '👑' : '·'
        name = u.name.to_s.empty? ? u.uid.to_s : u.name.to_s
        [btn("#{flag} #{name}", "adm:user:#{u.uid}")]
      }
      nav = []
      nav << btn('⏪', "adm:admins:#{page - 1}") if page > 0
      nav << btn('⏩', "adm:admins:#{page + 1}") if page < pages - 1
      buttons << nav unless nav.empty?
      buttons << [btn('⬅️ Назад', 'adm:root')]

      text = "Админы и недавние пользователи (стр. #{page + 1}/#{pages})"
      { text: text, reply_markup: inline(buttons) }
    end

    def user_detail(uid:)
      user = User.find_by(uid: uid)
      return { text: "uid #{uid} не найден", reply_markup: inline([[btn('⬅️ Назад', 'adm:admins:0')]]) } unless user

      label = user.role == 'admin' ? '⬇️ Снять роль admin' : '👑 Назначить admin'
      buttons = [
        [link_btn('👤 Открыть профиль', "tg://user?id=#{uid}")],
        [btn(label, "adm:user_toggle:#{uid}")],
        [btn('⬅️ Назад', 'adm:admins:0')],
      ]
      lines = [
        user.name.to_s.empty? ? "uid: #{user.uid}" : "#{user.name} (uid: #{user.uid})",
        "role: #{user.role || '(none)'}",
      ]
      { text: lines.join("\n"), reply_markup: inline(buttons) }
    end

    def status
      auth_chats = Chat.where(authorized: true).count
      since = Time.now - 24 * 3600
      msgs_24h = Message.where('created_at > ?', since).count rescue 0
      fails_24h = BackgroundTask.where(status: 'failed').where('created_at > ?', since).count rescue 0
      latest_failures = (BackgroundTask.where(status: 'failed').order(id: :desc).limit(5).to_a rescue [])
      lines = [
        "📊 Статус",
        "",
        "Авторизованных чатов: #{auth_chats}",
        "Сообщений за 24ч: #{msgs_24h}",
        "Failed background tasks за 24ч: #{fails_24h}",
      ]
      unless latest_failures.empty?
        lines << ""
        lines << "Последние ошибки:"
        latest_failures.each { |t|
          summary = (t.result.to_s[0, 60]).gsub(/\s+/, ' ')
          lines << "• #{t.task_type} ##{t.id}: #{summary}"
        }
      end
      kb = inline([
        [btn('🔄 Обновить', 'adm:status')],
        [btn('⬅️ Назад',    'adm:root')],
      ])
      { text: lines.join("\n"), reply_markup: kb }
    end

    # Replaces a /start access-request notification after the admin acted.
    def request_resolved(chat_id:, accepted:)
      chat = Chat.find_by(chat_id: chat_id)
      label = chat ? display_title(chat) : chat_id.to_s
      verdict = accepted ? "✅ Принят: #{label}" : "❌ Отклонён: #{label}"
      { text: "#{verdict} (id: #{chat_id})",
        reply_markup: inline([[btn('⚙️ Детали чата', "adm:chat:#{chat_id}")]]) }
    end

    def confirm_last_authorized_off(chat_id:)
      kb = inline([
        [btn('✅ Да, отключить', "adm:chat_toggle_auth_confirm:#{chat_id}")],
        [btn('❌ Отмена',         "adm:chat:#{chat_id}")],
      ])
      { text: "Останется 0 авторизованных чатов. Точно?", reply_markup: kb }
    end

    # Legacy config-seeded rows carry the literal title "unknown" — as
    # useless as an empty one. Fall back to the chat_id so every button is
    # at least identifiable. (Single source of truth lives on the model.)
    def unknown_title?(title)
      Chat.unknown_title?(title)
    end

    def display_title(chat)
      unknown_title?(chat.title) ? chat.chat_id.to_s : chat.title.to_s
    end

    # Self-heal unknown titles while browsing: ask Telegram for the chat's
    # current title/name and persist it. AUTHORIZED rows only — these calls
    # run synchronously in bot.listen's single-threaded loop. Failures must
    # NOT retry on every page render (each 400 costs ~1s of whole-bot
    # stall, verified on prod): a definitive "chat not found" persists a
    # 💀-marker title (never retried, visibly flags the dead row — a later
    # real message overwrites it via touch_seen IF the chat returns with a
    # derivable name; groups always have one); any other error goes
    # into an in-process negative cache (retried only after a restart).
    def refresh_titles!(rows, api)
      @getchat_failed ||= Set.new
      rows.each do |c|
        next unless c.authorized && unknown_title?(c.title)
        next if @getchat_failed.include?(c.chat_id)
        begin
          info = api.getChat(chat_id: c.chat_id)
          t = chat_label_from(info)
          c.update!(title: t) if t && !t.empty?
        rescue => e
          if e.message.include?('chat not found')
            c.update!(title: "💀 #{c.chat_id}")
          else
            @getchat_failed << c.chat_id
          end
          LOGGER.debug "[admin_menu] getChat(#{c.chat_id}) failed: #{e.class}: #{e.message}" if defined?(LOGGER)
        end
      end
    end

    def reset_getchat_cache_for_test!
      @getchat_failed = Set.new
      @chat_link_cache = {}
    end

    # Groups have .title; private chats have first/last name + username.
    def chat_label_from(info)
      Chat.label_from_telegram(info)
    end

    # "Open" button for the chat detail view so an admin can jump to the
    # chat/user from the menu. A private chat IS a user (chat_id == the
    # user's uid), so link straight to the profile card via tg://user?id —
    # no API call, always available. Groups/channels have no id-based deep
    # link: fall back to a public https://t.me/<username> (or the primary
    # invite link) discovered via getChat — authorized rows only (same
    # single-threaded-loop rationale as refresh_titles!). Returns nil when
    # nothing is linkable (the common case for private groups).
    def chat_open_button(chat, api)
      if chat.chat_type == 'private'
        return link_btn('👤 Открыть профиль', "tg://user?id=#{chat.chat_id}")
      end
      return nil unless api && chat.authorized
      url = chat_public_url(chat.chat_id, api)
      url && link_btn('🔗 Открыть чат', url)
    end

    # Resolve a public URL for a group/channel via getChat. Caching is
    # SELECTIVE (mirrors refresh_titles!'s definitive-vs-transient split), so
    # repeatedly opening a detail view never hammers the single-threaded loop
    # for the stable cases, while dead/rotated links self-heal:
    #   • public @username → stable → cached
    #   • primary invite link → revocable/rotatable → returned live, NOT cached
    #   • genuine miss (private group, no handle) → cached (spares getChat)
    #   • "chat not found" → permanent → cached; any other (transient) error
    #     (429 / network / proxy) → NOT cached, retried on the next open
    def chat_public_url(chat_id, api)
      @chat_link_cache ||= {}
      return @chat_link_cache[chat_id] if @chat_link_cache.key?(chat_id)
      begin
        info  = api.getChat(chat_id: chat_id)
        uname = tg_attr(info, :username).to_s.strip
        return @chat_link_cache[chat_id] = "https://t.me/#{uname}" unless uname.empty?
        link = tg_attr(info, :invite_link).to_s.strip
        return link unless link.empty? # live, never cached — invites get revoked
        @chat_link_cache[chat_id] = nil # genuine miss → cache to spare getChat
      rescue => e
        LOGGER.debug "[admin_menu] getChat(#{chat_id}) link fetch: #{e.class}: #{e.message}" if defined?(LOGGER)
        @chat_link_cache[chat_id] = nil if e.message.to_s.include?('chat not found')
        nil
      end
    end

    # Read a field off a getChat result across gem-2.x typed structs and
    # Hash/'result'-enveloped shapes (mirrors Chat.label_from_telegram).
    def tg_attr(info, key)
      if info.respond_to?(key)
        info.public_send(key)
      elsif info.is_a?(Hash)
        info.dig('result', key.to_s) || info[key.to_s]
      end
    end

    def btn(text, callback_data)
      Telegram::Bot::Types::InlineKeyboardButton.new(text: text, callback_data: callback_data)
    end

    def link_btn(text, url)
      Telegram::Bot::Types::InlineKeyboardButton.new(text: text, url: url)
    end

    def inline(rows)
      Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: rows)
    end
  end
end
