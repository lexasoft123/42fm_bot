require 'marky_markov'

class Markov
  attr_accessor :md

  @@wildcard = './db/markov/*.mmd'

  def initialize
    dict = get_dictionary
    @md = MarkyMarkov::Dictionary.new dict
  end

  def self.gen_text
    m = Markov.new
    m.md.generate_n_sentences 5
  end

  def get_dictionary(name = nil)
    dicts = []
    Dir.glob(@@wildcard) do |dict|
      dicts << dict.gsub(/\.mmd/, "")
    end
    dicts.sample
  end

end
