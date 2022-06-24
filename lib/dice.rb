require 'yaml'

class Dice

  def initialize username
    @replies = YAML.load File.read Dir.glob('config/lib/dice.yml').first
    @username = username
  end

  def play!
    res = []
    resp = []
    4.times{|i| res << (rand(6) + 1) }
    total = res[0] + res[1] - res[2] - res[3]

    resp << @replies["play"].sample % {
                                username: @username,
                                user_dice_one: res[0],
                                user_dice_two: res[1],
                                bot_dice_one:  res[2],
                                bot_dice_two:  res[3]
                              }
    resp << "..."

    resp << @replies["win"].sample  % {username: @username} if total > 0
    resp << @replies["lose"].sample % {username: @username} if total < 0
    resp << @replies["draw"].sample if total == 0

    resp.join("\n")
  end

end
