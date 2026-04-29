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

    def chats(page: 0)
      total = Chat.count
      pages = [(total + PAGE_SIZE - 1) / PAGE_SIZE, 1].max
      page  = page.clamp(0, pages - 1)
      rows  = Chat.order(:chat_id).offset(page * PAGE_SIZE).limit(PAGE_SIZE).to_a

      buttons = rows.map { |c|
        flag  = c.authorized ? '✓' : '✗'
        audio = c.audio      ? ' 🎵' : ''
        title = (c.title.to_s.empty? ? c.chat_id.to_s : c.title.to_s)
        [btn("#{flag} #{title}#{audio}", "adm:chat:#{c.chat_id}")]
      }

      nav = []
      nav << btn('⏪', "adm:chats:#{page - 1}") if page > 0
      nav << btn('⏩', "adm:chats:#{page + 1}") if page < pages - 1
      buttons << nav unless nav.empty?
      buttons << [btn('⬅️ Назад', 'adm:root')]

      text = "Чаты (стр. #{page + 1}/#{pages}, всего #{total})"
      { text: text, reply_markup: inline(buttons) }
    end

    def chat_detail(chat_id:)
      chat = Chat.find_by(chat_id: chat_id)
      return { text: "Чат #{chat_id} не найден", reply_markup: inline([[btn('⬅️ Назад', 'adm:chats:0')]]) } unless chat

      auth_label  = chat.authorized ? '🔒 Деавторизовать' : '🔓 Авторизовать'
      audio_label = chat.audio      ? '🎵 Аудио: вкл'      : '🎵 Аудио: выкл'

      buttons = [
        [btn(auth_label,   "adm:chat_toggle_auth:#{chat_id}")],
        [btn(audio_label,  "adm:chat_toggle_audio:#{chat_id}")],
        [btn('⚙️ Лимиты',  "adm:chat_limits:#{chat_id}")],
        [btn('⬅️ Назад',   'adm:chats:0')],
      ]

      lines = [
        chat.title.to_s.empty? ? "id: #{chat.chat_id}" : "#{chat.title} (id: #{chat.chat_id})",
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

      text = "Лимиты для «#{chat.title || chat_id}»\n\nНажми бакет, чтобы изменить."
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

    def confirm_last_authorized_off(chat_id:)
      kb = inline([
        [btn('✅ Да, отключить', "adm:chat_toggle_auth_confirm:#{chat_id}")],
        [btn('❌ Отмена',         "adm:chat:#{chat_id}")],
      ])
      { text: "Останется 0 авторизованных чатов. Точно?", reply_markup: kb }
    end

    def btn(text, callback_data)
      Telegram::Bot::Types::InlineKeyboardButton.new(text: text, callback_data: callback_data)
    end

    def inline(rows)
      Telegram::Bot::Types::InlineKeyboardMarkup.new(inline_keyboard: rows)
    end
  end
end
