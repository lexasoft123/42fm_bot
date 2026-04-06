module Fixtures
  module Songs
    def metallica(attrs = {})
      Song.create!({ artist: "Metallica", title: "Master of Puppets", filepath: "metallica/master.mp3" }.merge(attrs))
    end

    def nirvana(attrs = {})
      Song.create!({ artist: "Nirvana", title: "Smells Like Teen Spirit", filepath: "nirvana/smells.mp3" }.merge(attrs))
    end

    def pink_floyd(attrs = {})
      Song.create!({ artist: "Pink Floyd", title: "Comfortably Numb", filepath: "floyd/comf.mp3", year: 1979 }.merge(attrs))
    end

    def acdc(attrs = {})
      Song.create!({ artist: "AC/DC", title: "Back in Black", filepath: "acdc/bib.mp3" }.merge(attrs))
    end

    def celine_dion(attrs = {})
      Song.create!({ artist: "Celine Dion", title: "My Heart Will Go On", filepath: "celine/heart.mp3" }.merge(attrs))
    end

    def george_harrison(attrs = {})
      Song.create!({ artist: "George Harrison", title: "My Sweet Lord", filepath: "harrison/lord.mp3" }.merge(attrs))
    end

    def johnny_cash(attrs = {})
      Song.create!({ artist: "Johnny Cash", title: "Solitary Man", filepath: "cash/solitary.mp3" }.merge(attrs))
    end

    def iron_maiden(attrs = {})
      Song.create!({ artist: "Iron Maiden", title: "Fear of the Dark", filepath: "maiden/fear.mp3" }.merge(attrs))
    end

    def gazmanov(attrs = {})
      Song.create!({ artist: "Gazmanov", title: "Escobar", filepath: "gazmanov/escobar.mp3" }.merge(attrs))
    end

    def uratsakidogi(attrs = {})
      Song.create!({ artist: "Uratsakidogi", title: "Some Track", filepath: "uratsa/track.mp3" }.merge(attrs))
    end

    def stalker_guitar(attrs = {})
      Song.create!({ artist: "Stalker Blues", title: "Guitar Tone", filepath: "stalker/guitar.mp3" }.merge(attrs))
    end
  end
end
