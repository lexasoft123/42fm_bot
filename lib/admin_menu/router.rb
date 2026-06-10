module AdminMenu
  module Router
    Action = Struct.new(:kind, :view, :params, :answer, keyword_init: true) do
      def render?    = kind == :render
      def mutating?  = kind == :mutate
      def close?     = kind == :close
      def input?     = kind == :await_input
      def unknown?   = kind == :unknown
    end

    module_function

    def parse(callback_data)
      parts = callback_data.to_s.split(':')
      return Action.new(kind: :unknown, answer: '🚫 unknown') unless parts.first == 'adm'
      view = parts[1]
      args = parts[2..] || []

      case view
      when 'root'
        Action.new(kind: :render, view: :root, params: {})
      when 'close'
        Action.new(kind: :close, params: {}, answer: '')
      when 'chats'
        Action.new(kind: :render, view: :chats, params: { page: args[0].to_i })
      when 'chat'
        Action.new(kind: :render, view: :chat_detail, params: { chat_id: args[0].to_i })
      when 'chat_toggle_auth'
        Action.new(kind: :mutate, view: :toggle_auth, params: { chat_id: args[0].to_i })
      when 'chat_toggle_auth_confirm'
        Action.new(kind: :mutate, view: :toggle_auth_confirm, params: { chat_id: args[0].to_i })
      when 'chat_toggle_audio'
        Action.new(kind: :mutate, view: :toggle_audio, params: { chat_id: args[0].to_i })
      when 'chat_limits'
        Action.new(kind: :render, view: :chat_limits, params: { chat_id: args[0].to_i })
      when 'chat_limit_edit'
        Action.new(kind: :await_input, view: :rate_limit, params: { chat_id: args[0].to_i, bucket: args[1].to_s })
      when 'admins'
        Action.new(kind: :render, view: :admins, params: { page: args[0].to_i })
      when 'user'
        Action.new(kind: :render, view: :user_detail, params: { uid: args[0].to_i })
      when 'user_toggle'
        Action.new(kind: :mutate, view: :user_toggle, params: { uid: args[0].to_i })
      when 'status'
        Action.new(kind: :render, view: :status, params: {})
      when 'req_accept'
        Action.new(kind: :mutate, view: :req_accept, params: { chat_id: args[0].to_i })
      when 'req_decline'
        Action.new(kind: :mutate, view: :req_decline, params: { chat_id: args[0].to_i })
      else
        Action.new(kind: :unknown, answer: '🚫 unknown')
      end
    end
  end
end
