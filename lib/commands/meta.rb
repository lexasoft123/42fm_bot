module Commands
  class Meta < Base
    PATTERN = /^!(meta|мета)/

    def match?
      cmd =~ PATTERN
    end

    def execute
      CommandResult.text(radio.meta)
    end
  end
end
