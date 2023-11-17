require "../../pdk/crystal/main"

fun pdk_test_on_timestamp
  ms = 3000
  STDERR.puts %(cizero.on_timestamp("pdk_test_on_timestamp_callback", 1000, #{ms}))
  now = Time.new(seconds: 0, nanoseconds: 0, location: Time::Location.fixed(0))
  Cizero.on_timestamp("pdk_test_on_timestamp_callback", now + ms.milliseconds, 1000i64)
end

fun pdk_test_on_timestamp_callback(user_data : Int64*, user_data_len : Int32)
  raise "Expected Int64" unless user_data_len == sizeof(Int64)
  STDERR.puts %(pdk_test_on_timestamp_callback(#{user_data.value}))
end

fun pdk_test_on_cron
  spec = "* * * * *"
  STDERR.puts %(cizero.on_cron("pdk_test_on_cron_callback", 1000, #{spec.inspect}) 60000)
  Cizero.on_cron("pdk_test_on_cron_callback", spec, 1000i64)
end

fun pdk_test_on_cron_callback(user_data : Int64*, user_data_len : Int32) : Int32
  raise "Expected Int64" unless user_data_len == sizeof(Int64)
  STDERR.puts %(pdk_test_on_cron_callback(#{user_data.value}))
  0
end

lib LibCizero
  struct Sample
    a : UInt8
    b : UInt8
    c : UInt8
  end
end

fun pdk_test_on_webhook
  STDERR.puts %(cizero.on_webhook("pdk_test_on_webhook_callback", .{ 25, 372 }))
  user_data = LibCizero::Sample.new
  user_data.a = 25
  user_data.b = 116
  user_data.c = 1
  Cizero.on_webhook("pdk_test_on_webhook_callback", user_data)
end

fun pdk_test_on_webhook_callback(user_data : LibCizero::Sample*, user_data_len : LibC::Int, body_ptr : UInt8*) : Bool
  raise "size doesn't match" unless user_data_len == sizeof(LibCizero::Sample)

  raise "wrong value for a" unless user_data.value.a == 25
  raise "wrong value for b" unless user_data.value.b == 116
  raise "wrong value for c" unless user_data.value.c == 1

  body = String.new body_ptr

  STDERR.puts %(pdk_test_on_webhook_callback(.{ #{user_data.value.a}, 372 }, #{body.inspect}))

  false
end

fun pdk_test_exec
  result = Cizero.exec(["sh", "-c", <<-SH], {"foo" => "bar"}, 50 * 1024)
  echo     stdout
  echo >&2 stderr \\$foo="$foo"
  SH

  STDERR.puts(<<-OUT)
  term tag: #{result.term_tag}
  term code: #{result.term_code}
  stdout: #{result.stdout}
  stderr: #{result.stderr}
  OUT
end
