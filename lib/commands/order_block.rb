module Commands
  class OrderBlock < Base
    PATTERN = /^!(заказ|request|req|замовлення)\s+(навоз|наво)/

    def match?
      cmd =~ PATTERN
    end

    def execute
      CommandResult.text("Ты хуй и ебаный узбек")
    end
  end
end
