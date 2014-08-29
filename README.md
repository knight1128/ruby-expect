ruby-expect(simple usage)
===========

The origin file of this ruby-expect github project is "https://github.com/abates/ruby_expect".

It merged two ruby file of the origin for simple usage. 


What is it?
-----------

Only one ruby script file can include ruby scripts. 

Origin github project is "https://github.com/abates/ruby_expect". 


Usage
-----------
- wget https://raw.githubusercontent.com/knight1128/ruby-expect/master/expect.rb
- use
```ruby
require_relative 'expect'

DB_USER_NAME  = "www"
DB_USER_PWD   = "wwwteam"

mysql_version = `mysql --version | tr [,] ' ' | tr [:space:] '\n' | grep -E '([0-9]{1,3}[\.]){2}[0-9]{1,3}'`

if mysql_version > "5.6.0"
  SUPPORT_MYSQL_5DOT6 = true
else
  SUPPORT_MYSQL_5DOT6 = false
end

if SUPPORT_MYSQL_5DOT6
  exp = RubyExpect::Expect.spawn("mysql_config_editor set --login-path=localhost --host=localhost --user=#{DB_USER_NAME} --password")
  exp.procedure do
    each do
        expect /Enter password:/ do
          send DB_USER_PWD
        end
    end
  end
end

```

