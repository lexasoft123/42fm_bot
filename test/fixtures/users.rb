module Fixtures
  module Users
    def member_user(attrs = {})
      User.create!({ uid: 1001, name: "testuser", role: "member" }.merge(attrs))
    end

    def admin_user(attrs = {})
      User.create!({ uid: 1002, name: "adminuser", role: "admin" }.merge(attrs))
    end
  end
end
