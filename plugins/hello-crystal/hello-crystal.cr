require "../../pdk/crystal/main"

fun on_timestamp
  puts "onTimestamp"
  puts Time.local(Time::Location.fixed(0)).to_s("%F %T")
end

fun on_cron
  puts "onCron"
  puts Time.local(Time::Location.fixed(0)).to_s("%F %T")
end

Cizero.on_timestamp("on_timestamp", (Time.local + 1.milliseconds)) 
Cizero.on_cron("on_cron", "* * * * *") 

puts Cizero.to_upper("Hello World!")

exec_result = Cizero.exec(["sh", "-c", <<-SH], {"hey" => "World"}, 300)
echo this goes to stdout
echo this goes to stderr >&2 
echo hey: $hey
SH

pp! exec_result.@exit_code
puts exec_result.@stdout
STDERR.puts exec_result.@stderr
