require "../../pdk/crystal/main"

puts Cizero.to_upper("Hello World!")

fun on_timestamp(ptr : UInt8*, len : Int32)
  if ptr.null?
    puts "onTimestamp (no userdata)"
  else
    pp! ptr, len
    puts "onTimeStamp #{String.new(ptr).inspect}"
  end
  puts Time.local(Time::Location.fixed(0)).to_s("%F %T")
end

fun on_cron(ptr : UInt8*, len : Int32) : Bool
  if ptr.null?
    puts "onCron (no userdata)"
  else
    pp! ptr, len
    puts "onCron #{String.new(ptr).inspect}"
  end
  puts Time.local(Time::Location.fixed(0)).to_s("%F %T")
  delete_after_run = false
end

Cizero.on_timestamp("on_timestamp", (Time.local + 1.milliseconds))
Cizero.on_timestamp("on_timestamp", (Time.local + 1.milliseconds), user_data: "hello".to_slice)
Cizero.on_cron("on_cron", "* * * * *")
Cizero.on_cron("on_cron", "* * * * *", user_data: "some userdata")

exec_result = Cizero.exec(["sh", "-c", <<-SH], {"hey" => "World"}, 300)
echo this goes to stdout
echo this goes to stderr >&2
echo hey: $hey
SH

pp! exec_result.@exit_code
puts exec_result.@stdout
STDERR.puts exec_result.@stderr
