require 'rss'
require 'yaml'
require 'unicode_utils'

require './lib/message_sender'
require './lib/reply_master'
require './lib/gogolmogol'
require './lib/weather'
require './lib/translator'
require './lib/dice'
require './lib/horoscope'
require './lib/markov'
require './lib/giphy_master'

class MessageResponder
  attr_reader :message
  attr_reader :bot
  attr_reader :user
  attr_reader :reply_master
  attr_reader :radio

  def initialize(options)
    @bot = options[:bot]
    @message = options[:message]
    @user = User.create_with(name: message.from.username,
        first_name: message.from.first_name,
        last_name: message.from.last_name,
        role: 'new').find_or_create_by(uid: message.from.id)
    update_user_data
    @reply_master = ReplyMaster.new
    @radio = options[:radio]
  end

  def respond

    p message

    # Do not process outdated messages
    return if message.date + 30 < Time.now.to_i

    process_voice_message if message.voice

    #if user = message.new_chat_participant
    #  if @banned_users.index user.id
    #
    #  end
    #end

    cmd = UnicodeUtils.downcase(message.text) if message.text

    res = nil

    # RADIO commands

    if cmd =~ /^!(заказ|request|req|замовлення)\s+(.*)$/

      if check_order_privileges
        tr = @radio.request $2
        if tr
          update_last_order
          res = tr[:name]
        else
          sticker_key = [:kiss_my_ass, :govnar, :lemmy].sample
          send_sticker! STICKER[sticker_key]
          return
        end
      else
        res = "А не охуел ли ты часом, %username%? Заказывай не ранее #{user.next_order}"
      end

    elsif cmd =~ /^!(search|поиск|пошукай)\s+(.*)$/

      if (["admin", "member"].include? user.role) and ($2.size >= 4)
        tr = @radio.search $2
        if not tr.empty?
          tr = tr.collect do |t|
            tp = t.split "/"
            tp.collect! {|tpp| tpp.gsub "_", " "}
            artist = tp[-2]
            name = tp[-1].gsub /.mp3/i, ""
            "#{artist} — #{name}"
          end
          res = tr.join("\n")
        else
          res = "Нихуя нет..."
        end
      end

    elsif cmd =~ /^!(трек|track)/
      res = @radio.track

    elsif cmd =~ /^!(статистика|стата)\s+(сегодня|день)$/
      send_picture! "http://stats.42fm.ru/ru/42fm.ru/icecast-day.png"
      return

    elsif cmd =~ /^!(статистика|стата)\s+месяц$/
      send_picture! "http://stats.42fm.ru/ru/42fm.ru/icecast-month.png"
      return

    elsif cmd =~ /^!(статистика|стата)(\s+неделя)?$/
      send_picture! "http://stats.42fm.ru/ru/42fm.ru/icecast-week.png"
      return

    elsif cmd =~ /^!(queue|очередь|куеуе)/
      q = @radio.queue
      res = q ? q : "нихуя нет"
    elsif cmd =~ /!погода\s+(?<city>.*)/
      city = Regexp.last_match(:city)
      res = Weather.new(city).search!
    elsif cmd =~ /^!(слушатели|listeners|слухачі)/
      q = @radio.listeners
      res = q ? "Сейчас нас слушают: #{q}" : "все куда-то съебли"

    elsif cmd =~ /^!(убрать|нахуй|remove|попячь|убери)[,]?\s+(пожалуйста\s+)?(?<tracks>(\d+\s*)+)/
      if user.role != "new"
        tr = @radio.remove Regexp.last_match(:tracks).split("\s")
        res = tr ? "Попячено!" : "Внезапно Джигурда"
      else
        res = "ложись спать, тебе завтра рано в школу"
      end

    elsif cmd =~ /^!(remaining|осталось|терпеть)/
      res = @radio.remaining

    elsif cmd =~ /^!(history|история)/
      res = @radio.history

    elsif cmd =~ /^!(top|топ)\s+(\d+)/
      res = @radio.top $2

    elsif cmd =~ /^!(meta|мета)/
      res = @radio.meta

    elsif cmd =~ /^!(help|помощь|команды|хелп|чокак)$/

      res = [
        "DJ Жзяцля знает следующие команды:",
        "!трек !track — текущий трек",
        "!queue !очередь — очередь заказов",
        "!слушатели !listeners — кол-во слушателей радио в данный момент",
        "!заказ !request !req — заказ трека",
        "!убрать ID — удалить трек из очереди",
        "!remaining !осталось — сколько осталось до конца трека",
        "!history !история — что играло раньше",
        "!топ !top ID — топ",
        "!мета !meta — метаданные трека",
        "!статистика [день|неделя|месяц] - стата за день/неделю/месяц",
        "!погода city[,country_code] - погода",
        "бот|жзяцля пиздани|укр текст - піздануть мовою",
        "бот|жзяцля бульбани текст - пиздануть беларускай моваю",
        "бот|жзяцля [найди|ищи] [фото] — поиск фото",
        "бот|жзяцля гиф — поиск гифов",
        "бот|жзяцля [пиши|пейши] — бот у мамки пейсатель"
          ].join "\n"


    # FUN commands

    elsif cmd =~ /^(бот|жзяцля)\s+(вещай|гороскоп)$/
      res = Horoscope.new(@user.name).predict!

    elsif cmd =~ /^((бот|жзяцля)[,]?\s+((чо\s+(там|нового).*)|(новости))|!новости|!news)$/i
      src = 'https://lenta.ru/rss'
      rss = RSS::Parser.parse(src, false)
      item = rss.items.sample
      res = item.title + "\n\n" + item.description.gsub(/^\s+/,'')

    elsif cmd =~ /^((бот|жзяцля)[,]?\s+(баш|ебаш)|!баш|!bash)$/i
      src = "http://bash.im/rss/"
      rss = RSS::Parser.parse(src, false)
      item = rss.items.sample
      res = Nokogiri::HTML(item.description.gsub(/<br>/,"\n")).text

    elsif cmd =~ /^(бот|жзяцля)\s+(пиши|пейши)$/
      res = Markov.gen_text

    elsif cmd =~ /^(бот|жзяцля|тугосеря)[,]?\s+(?<lang>#{Translator::ALIASES.keys.join("|")})\s+(?<text>.*)$/mi
      res = Translator.new(Regexp.last_match(:text)).translate_alias! Regexp.last_match(:lang)

    elsif cmd =~ /^(!|(бот[,]?.*\s))кости$/i
      res = Dice.new(@user.name).play!

    elsif cmd =~ /^(бот|жзяцля|тугосеря|уважаемый\sбот)[,]?\s(((т|в)ы\s)|(гей|пидор|мудак)).*/i
      res = @reply_master.reply_you(@user, @message.from, cmd)

    elsif cmd =~ /^(бот)\s+(топ)$/
      stats = Phrase.joins(:user).
          select('users.name as username, COUNT(phrases.id) as p_count').
          group('users.id').order('p_count desc').limit("15")

      count = Phrase.count
      res = stats.map{|s| "#{s.p_count} — #{s.username}"}.join("\n")
      res += "\nВсего: #{count}"

    elsif cmd =~ /^(бот|жзяцля|тугосеря|уважаемый\sбот)\sгиф\s+(.*)$/
      gif = GiphyMaster.search $2
      res = "Нихера не нашол." if !gif
      MessageSender.new(bot: bot, chat: message.chat, text: gif).send_image

    elsif cmd =~ /^(бот|жзяцля|тугосеря|уважаемый\sбот)/i

      if user.role == 'new' and not (cmd =~ /^уважаемый/i) and (rand(100) < 10)
        res = "Уважаемый бот."
      else

        query = cmd.gsub(/(бот|уважаемый\sбот|жзяцля|.*гугли|найди|ищи|искать)\s*/, '')
        res = Gogolmogol.new(query).search!
        if res && res =~ /[.](jpg|jpeg|gif|png|tif|bmp)/
          MessageSender.new(bot: bot, chat: message.chat, text: res).send_image
          return
        end
      end

    else
      res = @reply_master.reply(@user, @message.from, cmd)
    end

    MessageSender.new(bot: bot, chat: message.chat, text: res).send if res

  end

  def send_sticker! file_id
    MessageSender.new(bot: bot, chat: message.chat, text: file_id).send_sticker
  end

  def send_picture! url
    MessageSender.new(bot: bot, chat: message.chat, text: url).send_image
  end

  private

  def check_order_privileges
    case user.role
    when 'new'
      return false if (user.last_order and (Time.now < user.next_order))
      return true
    when 'member'
      return true
    when 'admin'
      return true
    end
  end

  def update_last_order
    user.last_order = Time.now
    user.save
  end

  def update_user_data
    if ((user.name != message.from.username) or (user.first_name != message.from.first_name))
      user.name = message.from.username
      user.first_name = message.from.first_name
      user.last_name = message.from.last_name
      user.save
    end
  end

  def process_voice_message
    return false if not AUDIO_CHAT.include? message.chat.id

    file_id = message.voice.file_id
    file = bot.api.getFile(file_id: file_id)
    file_path = file['result']['file_path']
    p file

    return false if message.voice.mime_type != "audio/ogg"

    link = "https://api.telegram.org/file/bot#{'193030644:AAH19Yc_cvjNzT9luvgnA13TGW9cWYrL55Q'}/#{file_path}"

    MessageSender.new(bot: bot, chat: message.chat, text: link).send

  end

end
